#!/bin/bash
# run-job.sh — 汎用ジョブランナー（timeout/retry/concurrency forbid/metrics/通知）
# Usage: run-job.sh <job-name>
#
# jobs.json からジョブ定義を読み、claude -p を実行する。
# - concurrency forbid: mkdir ロック（sync-config.sh 方式）
# - timeout: bash 自前実装（プロセスグループ kill + フラグファイル判定）
# - retry: backoff_limit 回まで30秒間隔
# - metrics: ~/.claude/metrics/jobs-YYYY-MM.jsonl に1行JSON追記
# - 通知: 最終失敗時のみ osascript
# - 後段チェック: ok確定後、memory受信箱の直近1時間更新ファイルをsecretスキャンしquarantine

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JOB_NAME="${1:?Usage: run-job.sh <job-name>}"

JOBS_JSON="${SCRIPT_DIR}/jobs.json"
LOG_DIR="${SCRIPT_DIR}/../logs/jobs"
METRICS_DIR="$HOME/.claude/metrics"
# claude はPATH解決を優先（テスト時にダミーをPATH先頭へ差し込める）。
# launchd 環境では PATH に ~/.local/bin が無いため既定のパスにフォールバック
if command -v claude >/dev/null 2>&1; then
  CLAUDE_BIN="$(command -v claude)"
else
  CLAUDE_BIN="$HOME/.local/bin/claude"
fi
# auto memory の受信箱。ディレクトリ名は $HOME の / を - に置換したスラグ
HOME_SLUG="$(printf '%s' "$HOME" | tr '/' '-')"
MEMORY_DIR="$HOME/.claude/projects/${HOME_SLUG}/memory"

SECRET_PATTERNS='sk-ant-[A-Za-z0-9_-]{8,}|sk-proj-[A-Za-z0-9_-]{8,}|AIza[0-9A-Za-z_-]{30,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|glpat-[A-Za-z0-9_-]{15,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY'

mkdir -p "$LOG_DIR"
mkdir -p "$METRICS_DIR"

LOG_FILE="${LOG_DIR}/${JOB_NAME}-$(date +%Y%m%d).log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG_FILE"
}

# 30日超のログファイルを削除（このジョブのログディレクトリ内）
if find "$LOG_DIR" -maxdepth 1 -name "${JOB_NAME}-*.log" -mtime +30 -print 2>/dev/null | grep -q .; then
  find "$LOG_DIR" -maxdepth 1 -name "${JOB_NAME}-*.log" -mtime +30 -delete 2>/dev/null || true
fi

log "=== run-job.sh invoked for job=${JOB_NAME} ==="

# --- ジョブ定義読み込み ---
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found in PATH" >&2
  log "ERROR: jq not found"
  exit 0
fi

if [[ ! -f "$JOBS_JSON" ]]; then
  echo "ERROR: jobs.json not found at $JOBS_JSON" >&2
  log "ERROR: jobs.json not found"
  exit 0
fi

JOB_DEF="$(jq --arg name "$JOB_NAME" '.jobs[] | select(.name==$name)' "$JOBS_JSON" 2>/dev/null || true)"

if [[ -z "$JOB_DEF" ]]; then
  echo "ERROR: job '${JOB_NAME}' not found in jobs.json" >&2
  log "ERROR: job not found in jobs.json"
  exit 0
fi

ENABLED="$(jq -r '.enabled' <<<"$JOB_DEF")"
if [[ "$ENABLED" != "true" ]]; then
  echo "INFO: job '${JOB_NAME}' is disabled (enabled=${ENABLED})" >&2
  log "INFO: job disabled, exiting"
  exit 0
fi

PROMPT_FILE_REL="$(jq -r '.prompt_file' <<<"$JOB_DEF")"
MODEL="$(jq -r '.model' <<<"$JOB_DEF")"
ALLOWED_TOOLS="$(jq -r '.allowed_tools' <<<"$JOB_DEF")"
PERMISSION_MODE="$(jq -r '.permission_mode' <<<"$JOB_DEF")"
TIMEOUT_SECONDS="$(jq -r '.timeout_seconds' <<<"$JOB_DEF")"
BACKOFF_LIMIT="$(jq -r '.backoff_limit' <<<"$JOB_DEF")"
JOB_CWD_RAW="$(jq -r '.cwd' <<<"$JOB_DEF")"

# ~ 展開
JOB_CWD="${JOB_CWD_RAW/#\~/$HOME}"

# prompt_file は jobs.json (= scripts/jobs/) 基準の相対パス
PROMPT_FILE="${SCRIPT_DIR}/${PROMPT_FILE_REL}"

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: prompt_file not found: $PROMPT_FILE" >&2
  log "ERROR: prompt_file not found: $PROMPT_FILE"
  exit 0
fi

if [[ ! -d "$JOB_CWD" ]]; then
  echo "ERROR: cwd not found: $JOB_CWD" >&2
  log "ERROR: cwd not found: $JOB_CWD"
  exit 0
fi

# --- concurrency forbid: mkdir ロック ---
LOCK_DIR="${SCRIPT_DIR}/.lock-${JOB_NAME}"

record_metric() {
  local status="$1" attempts="$2" duration_s="$3"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local metrics_file="${METRICS_DIR}/jobs-$(date +%Y-%m).jsonl"
  jq -nc --arg ts "$ts" --arg job "$JOB_NAME" --arg status "$status" \
    --argjson attempts "$attempts" --argjson duration_s "$duration_s" \
    '{ts:$ts, job:$job, status:$status, attempts:$attempts, duration_s:$duration_s}' \
    >>"$metrics_file" 2>>"$LOG_FILE" || true
}

notify_failure() {
  local msg="$1"
  /usr/bin/osascript -e "display notification \"${msg}\" with title \"job runner: ${JOB_NAME}\" sound name \"Basso\"" 2>/dev/null || true
}

# 60分超の残骸ロックは除去してから再取得を試みる
if [ -d "$LOCK_DIR" ] && [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
  log "INFO: removing stale lock dir (>60min): $LOCK_DIR"
  rmdir "$LOCK_DIR" 2>/dev/null || true
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "INFO: lock acquisition failed, another run in progress. status=skipped_lock"
  record_metric "skipped_lock" 0 0
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# --- claude 呼び出し（タイムアウト+リトライ付き） ---
PROMPT_CONTENT="$(cat "$PROMPT_FILE")"

# 1回分の試行を実行する。戻り値: 0=ok, 1=fail, 2=timeout
run_once() {
  local attempt_no="$1"
  local timeout_flag
  timeout_flag="$(mktemp "${LOG_DIR}/.timeout-flag.${JOB_NAME}.${attempt_no}.XXXXXX")"
  rm -f "$timeout_flag" # 存在有無だけで判定するため、ここでは一旦消す（mktempは作成するため）

  local claude_pid watchdog_pid
  local claude_rc=0

  (
    cd "$JOB_CWD" || exit 1
    exec "$CLAUDE_BIN" -p \
      --model "$MODEL" \
      --allowedTools "$ALLOWED_TOOLS" \
      --permission-mode "$PERMISSION_MODE" \
      --no-session-persistence \
      "$PROMPT_CONTENT" >>"$LOG_FILE" 2>&1
  ) &
  claude_pid=$!

  # watchdog: timeout_seconds 経過してもclaude_pidが生きていればフラグを立てて殺す
  (
    sleep "$TIMEOUT_SECONDS"
    if kill -0 "$claude_pid" 2>/dev/null; then
      : >"$timeout_flag"
      kill -TERM "-$claude_pid" 2>/dev/null || true
      sleep 10
      if kill -0 "$claude_pid" 2>/dev/null; then
        kill -KILL "-$claude_pid" 2>/dev/null || true
      fi
    fi
  ) &
  watchdog_pid=$!

  # claude本体の終了を待つ。
  # 注意: ここで set +e / set -e をトグルしてはならない。関数内の set -e は
  # グローバルに効くため、呼び出し側の set +e を無効化し、return 2/1 の瞬間に
  # errexit がスクリプト全体を殺す（metrics/retry/通知が全てスキップされる）。
  claude_rc=0
  wait "$claude_pid" || claude_rc=$?

  # 正常系（timeoutでなければ）watchdogを明示killしてゾンビ化回避
  # set -m 下で watchdog はプロセスグループリーダーなので、グループごと殺す
  # （単体killだと内部の sleep <timeout_seconds> が残骸プロセスとして残る）
  if kill -0 "$watchdog_pid" 2>/dev/null; then
    kill -TERM -- "-$watchdog_pid" 2>/dev/null || true
  fi
  wait "$watchdog_pid" 2>/dev/null || true

  # timeout判定はフラグファイルの有無のみで確定
  if [[ -e "$timeout_flag" ]]; then
    rm -f "$timeout_flag" 2>/dev/null || true
    log "attempt ${attempt_no}: TIMEOUT (>${TIMEOUT_SECONDS}s), claude_rc=${claude_rc}"
    return 2
  fi

  rm -f "$timeout_flag" 2>/dev/null || true

  if [[ "$claude_rc" -ne 0 ]]; then
    log "attempt ${attempt_no}: FAIL rc=${claude_rc}"
    return 1
  fi

  log "attempt ${attempt_no}: OK"
  return 0
}

set -m # ジョブ制御を有効化し、バックグラウンドジョブを独立プロセスグループにする

START_TS=$(date +%s)
ATTEMPTS=0
FINAL_STATUS="fail"
MAX_ATTEMPTS=$((BACKOFF_LIMIT + 1))

while [[ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]]; do
  ATTEMPTS=$((ATTEMPTS + 1))
  log "--- attempt ${ATTEMPTS}/${MAX_ATTEMPTS} ---"

  set +e
  run_once "$ATTEMPTS"
  RESULT=$?
  set -e

  if [[ "$RESULT" -eq 0 ]]; then
    FINAL_STATUS="ok"
    break
  elif [[ "$RESULT" -eq 2 ]]; then
    FINAL_STATUS="timeout"
  else
    FINAL_STATUS="fail"
  fi

  if [[ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]]; then
    log "retrying in 30s (status=${FINAL_STATUS})"
    sleep 30
  fi
done

END_TS=$(date +%s)
DURATION_S=$((END_TS - START_TS))

log "=== job ${JOB_NAME} finished: status=${FINAL_STATUS} attempts=${ATTEMPTS} duration_s=${DURATION_S} ==="
record_metric "$FINAL_STATUS" "$ATTEMPTS" "$DURATION_S"

if [[ "$FINAL_STATUS" != "ok" ]]; then
  notify_failure "ジョブ ${JOB_NAME} が ${ATTEMPTS} 回の試行後も失敗しました (status=${FINAL_STATUS})"
  exit 0
fi

# --- 後段チェック: secret quarantine ---
# ジョブがokになった場合のみ。memory受信箱の直近1時間以内に変更されたファイルをスキャン
if [[ -d "$MEMORY_DIR" ]]; then
  while IFS= read -r -d '' f; do
    [[ "$f" == *.quarantine ]] && continue
    if grep -qE "$SECRET_PATTERNS" "$f" 2>/dev/null; then
      mv -f "$f" "${f}.quarantine" 2>/dev/null || true
      log "WARN: quarantined suspicious memory file: ${f} -> ${f}.quarantine"
      /usr/bin/osascript -e "display notification \"memoryファイルにsecretらしき文字列を検出したためquarantineしました: $(basename "$f")\" with title \"job runner: ${JOB_NAME}\" sound name \"Basso\"" 2>/dev/null || true
    fi
  done < <(find "$MEMORY_DIR" -type f -mmin -60 -print0 2>/dev/null)
fi

# --- 後段チェック: Obsidian Vault (PermanentNote) の secret スキャン ---
# Vault は obsidian-git が毎分自動 commit+push するため、vault 内リネームでは不十分
# （リネーム後もpushされ続ける）。検出時は vault 外の隔離ディレクトリへ「移動」する。
# なお自動pushの間隔より後にこのスキャンが走るため、既にpush済みの可能性がある。
# その場合は通知を見た人間が git 履歴の確認・除去を行う（一次防御はあくまでプロンプトのPIIガード）。
VAULT_PN_DIR="$HOME/Desktop/Obsidian/Zettelkasten/PermanentNote"
QUARANTINE_DIR="$HOME/.claude/.context/quarantine"
if [[ -d "$VAULT_PN_DIR" ]]; then
  while IFS= read -r -d '' f; do
    if grep -qE "$SECRET_PATTERNS" "$f" 2>/dev/null; then
      mkdir -p "$QUARANTINE_DIR" 2>/dev/null || true
      mv -f "$f" "${QUARANTINE_DIR}/$(basename "$f").quarantine" 2>/dev/null || true
      log "WARN: quarantined vault note (moved out of vault): ${f} -> ${QUARANTINE_DIR}/"
      /usr/bin/osascript -e "display notification \"Vaultノートにsecretらしき文字列を検出し隔離しました: $(basename "$f")。obsidian-gitが既にpushしている可能性があるため履歴を確認してください\" with title \"job runner: ${JOB_NAME}\" sound name \"Basso\"" 2>/dev/null || true
    fi
  done < <(find "$VAULT_PN_DIR" -type f -name '*.md' -mmin -60 -print0 2>/dev/null)
fi

exit 0
