#!/bin/bash
# .claude/hooks/block-secrets.sh v2
# PreToolUse hook. matcher: Bash|Read|Grep
#
# 設計思想（ambient-hardening-design.md Component 1）:
#   - fail-closed: 予期しない失敗は「黙って許可」せず exit 2 でブロック。
#     PreToolUse 仕様: exit 0(+JSONなし)=通常フロー(実質allow), exit 2=確実にブロック(stderrが理由)。
#   - set -euo pipefail を使う。ただし grep は必ず条件文脈(if grep ...)に置き、
#     裸の grep がマッチなし exit 1 で set -e 即死するのを防ぐ。$(...)代入は || true で受ける。
#   - 判定は JSON({permissionDecision:deny|ask}) を出して exit 0。最終防衛線のみ exit 2。

set -euo pipefail

# --- fail-closed: EXIT trap ---
# 1行目で rc を捕捉（後続で上書きされる前に）。0/2 以外なら stderr へ理由 + exit 2。
trap '
  rc=$?
  if [ "$rc" != "0" ] && [ "$rc" != "2" ]; then
    echo "block-secrets.sh: 予期しない終了 (rc=$rc)。fail-closed によりブロックします。" >&2
    exit 2
  fi
' EXIT

# --- jq 不在チェック ---
if ! command -v jq >/dev/null 2>&1; then
  echo "block-secrets.sh: jq が見つかりません。fail-closed によりブロックします。" >&2
  exit 2
fi

# --- 入力読み込み ---
INPUT=$(cat) || true

# 入力 JSON の妥当性チェック（壊れた入力は fail-closed でブロック）。
# 空入力は「対象なし」として通常フロー(exit 0)を許すが、非空かつ不正 JSON は exit 2。
if [ -n "$INPUT" ]; then
  if ! printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
    echo "block-secrets.sh: 入力 JSON が不正です。fail-closed によりブロックします。" >&2
    exit 2
  fi
fi

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty') || true
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty') || true

# ------------------------------------------------------------------
# ヘルパ: JSON 出力（v1 deny() と同じネスト形）
# ------------------------------------------------------------------
emit_decision() {
  # $1 = deny|ask, $2 = reason
  jq -n --arg decision "$1" --arg reason "$2" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: $decision,
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

deny() { emit_decision "deny" "$1"; }
ask()  { emit_decision "ask"  "$1"; }

# ------------------------------------------------------------------
# 秘密ファイル判定: basename ベースのパターン照合
# 戻り値 0 = 秘密ファイルパターンに合致
# ------------------------------------------------------------------
is_secret_pathlike() {
  # $1 = パス様トークン（ディレクトリを含みうる）
  local p="$1"
  local base
  base=$(basename -- "$p") || return 1

  # --- 許可（誤検知回避）: これらは秘密扱いしない ---
  case "$base" in
    .env.example|.env.sample|.env.template|.env.dist|.env.test) return 1 ;;
    *.pub) return 1 ;;
  esac

  # --- .env 完全一致 / .env.* ---
  if [ "$base" = ".env" ]; then return 0; fi
  case "$base" in
    .env.*) return 0 ;;
  esac

  # --- 拡張子ベース: *.pem *.key *.p12 *.pfx ---
  case "$base" in
    *.pem|*.key|*.p12|*.pfx) return 0 ;;
  esac

  # --- credentials*.json / service-account*.json / service_account*.json ---
  case "$base" in
    credentials*.json|service-account*.json|service_account*.json) return 0 ;;
  esac

  # --- 個別の既知ファイル名 ---
  case "$base" in
    credentials|.netrc|.npmrc|.pypirc) return 0 ;;
    id_*) case "$base" in *.pub) return 1 ;; *) return 0 ;; esac ;;
    environ) case "$p" in /proc/*/environ) return 0 ;; esac ;;
  esac

  return 1
}

# ------------------------------------------------------------------
# パス絶対化: cwd 基準 + チルダ/$HOME 展開。純文字列処理のみ（プロセス起動なし）。
# 毎 Bash コマンドの全トークンに対して呼ばれるため、ここで readlink/python3 を
# 起動してはならない（1コマンド1秒超の遅延実測あり）。
# ------------------------------------------------------------------
absolutize() {
  local p="$1"
  # チルダ展開
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  # $HOME リテラル展開
  case "$p" in
    '$HOME'|'${HOME}') p="$HOME" ;;
    '$HOME/'*) p="$HOME/${p#\$HOME/}" ;;
    '${HOME}/'*) p="$HOME/${p#\$\{HOME\}/}" ;;
  esac
  # cwd 基準で絶対パス化
  case "$p" in
    /*) : ;;
    *) [ -n "$CWD" ] && p="$CWD/$p" ;;
  esac
  printf '%s' "$p"
}

# ------------------------------------------------------------------
# symlink 解決: 絶対パスを受け取り実体パスを返す。
# 呼び出し側が [ -L ] で symlink と確認したときだけ呼ぶこと（プロセス起動を伴う）。
# ------------------------------------------------------------------
resolve_symlink() {
  local p="$1"
  local resolved=""
  if resolved=$(readlink -f -- "$p" 2>/dev/null) && [ -n "$resolved" ]; then
    printf '%s' "$resolved"
  elif command -v python3 >/dev/null 2>&1 && \
       resolved=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null) && \
       [ -n "$resolved" ]; then
    printf '%s' "$resolved"
  else
    printf '%s' "$p"
  fi
}

# 互換ラッパ（絶対化 + symlink のときのみ解決）
resolve_path() {
  local abs
  abs=$(absolutize "$1")
  if [ -L "$abs" ]; then
    resolve_symlink "$abs"
  else
    printf '%s' "$abs"
  fi
}

# ------------------------------------------------------------------
# 最低限のブレース展開: {a,b} を含む1トークンを複数トークンへ
# echo で改行区切り出力
# ------------------------------------------------------------------
brace_expand() {
  local tok="$1"
  # {a,b,c} を1組だけ含む単純ケースに対応
  case "$tok" in
    *"{"*","*"}"*)
      local pre inner post
      pre="${tok%%\{*}"
      inner="${tok#*\{}"
      inner="${inner%%\}*}"
      post="${tok#*\}}"
      local IFS=','
      local part
      for part in $inner; do
        printf '%s\n' "${pre}${part}${post}"
      done
      ;;
    *)
      printf '%s\n' "$tok"
      ;;
  esac
}

# ------------------------------------------------------------------
# Bash コマンドから「パス様トークン」を抽出し、実在する秘密ファイルなら ask
# ------------------------------------------------------------------
check_bash_read() {
  local command="$1"
  local tok
  # shellcheck disable=SC2086
  for tok in $command; do
    case "$tok" in
      -*|"") continue ;;
    esac
    tok="${tok%\"}"; tok="${tok#\"}"
    tok="${tok%\'}"; tok="${tok#\'}"
    tok="${tok%;}"; tok="${tok%,}"; tok="${tok%)}"; tok="${tok#(}"

    local expanded
    while IFS= read -r expanded; do
      [ -z "$expanded" ] && continue

      local candidates=()
      case "$expanded" in
        *"*"*|*"?"*|*"["*)
          local g
          while IFS= read -r g; do
            [ -n "$g" ] && candidates+=("$g")
          done < <(compgen -G "$expanded" 2>/dev/null || true)
          [ ${#candidates[@]} -eq 0 ] && candidates=("$expanded")
          ;;
        *)
          candidates=("$expanded")
          ;;
      esac

      local cand
      for cand in "${candidates[@]}"; do
        local abs
        abs=$(absolutize "$cand") || true
        # 1) トークン basename が秘密パターンに合致 → 実在チェック → ask
        if is_secret_pathlike "$cand"; then
          if [ -f "$abs" ]; then
            ask "秘密ファイルの読み取りの可能性があります: $cand"
          fi
        elif [ -L "$abs" ]; then
          # 2) トークン名は秘密パターンでないが symlink → リンク先を解決し
          #    リンク先 basename が秘密パターンなら ask（symlink 回避経路対策）。
          #    -L 確認後にのみ resolve_symlink（プロセス起動）を呼ぶ — 全トークンで
          #    起動すると1コマンド1秒超の遅延になる。
          local resolved
          resolved=$(resolve_symlink "$abs") || true
          if [ -f "$resolved" ] && is_secret_pathlike "$resolved"; then
            ask "秘密ファイル(シンボリックリンク経由)の読み取りの可能性があります: $cand"
          fi
        fi
      done
    done < <(brace_expand "$tok")
  done
}

# ==================================================================
# main: tool_name で分岐
# ==================================================================

if [ "$TOOL_NAME" = "Read" ]; then
  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty') || true
  if [ -n "$FILE_PATH" ] && is_secret_pathlike "$FILE_PATH"; then
    ask "秘密ファイルの読み取りの可能性があります: $FILE_PATH"
  fi
  exit 0
fi

if [ "$TOOL_NAME" = "Grep" ]; then
  GREP_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.path // empty') || true
  # path が秘密ファイルそのものを指すときのみ ask。ディレクトリ指定は対象外。
  if [ -n "$GREP_PATH" ] && is_secret_pathlike "$GREP_PATH"; then
    RESOLVED=$(resolve_path "$GREP_PATH") || true
    if [ -f "$RESOLVED" ]; then
      ask "秘密ファイルへの grep の可能性があります: $GREP_PATH"
    fi
    # 実在しなくても basename が明確に秘密ファイルなら ask（Read と揃える）
    # ただしディレクトリを指す場合は上の -f で弾かれる。
    if [ ! -e "$RESOLVED" ]; then
      ask "秘密ファイルへの grep の可能性があります: $GREP_PATH"
    fi
  fi
  exit 0
fi

# --- 以降 Bash ---
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty') || true

# コマンドが空なら何もしない
[ -z "$COMMAND" ] && exit 0

# ==================================================================
# v1 既存保護（維持）
# ==================================================================

# 先頭コマンド判定（読み取り系免除は「送信/削除系」判定にのみ使う。read検査には適用しない）
FIRST_CMD=$(printf '%s' "$COMMAND" | sed 's/|.*//' | awk '{print $1}' | xargs basename 2>/dev/null) || true
READONLY_CMDS="cat grep rg less head tail read vim vi code nano view wc diff"

is_readonly() {
  local c
  for c in $READONLY_CMDS; do
    [ "$1" = "$c" ] && return 0
  done
  return 1
}

# --- 秘密情報の漏洩・設定をブロック ---
if ! is_readonly "$FIRST_CMD"; then
  if printf '%s' "$COMMAND" | grep -qEi \
    '(export|set)\s+\w*(PASSWORD|SECRET|TOKEN|API_KEY)\w*=|'\
'(curl|wget|http)\b.*(-H|--header)\s.*\b(Authorization|Bearer|X-API-Key)\b|'\
'echo\s.*\$(PASSWORD|SECRET|TOKEN|API_KEY)\b'; then
    deny "秘密情報の代入・送信を含む可能性のあるコマンドがブロックされました"
  fi
fi

# --- .env / credentials ファイルへの書き込みをブロック（openssl 除外） ---
IS_OPENSSL=false
if printf '%s' "$COMMAND" | grep -qE '\bopenssl\b'; then IS_OPENSSL=true; fi

if [ "$IS_OPENSSL" = "false" ]; then
  if printf '%s' "$COMMAND" | grep -qE '(>|tee|cp|mv)\s+\S*\.(env|credentials|pem|key)\b'; then
    deny ".env / 認証ファイルへの書き込みがブロックされました（openssl での鍵/証明書生成は除外）"
  fi
fi

# --- 危険な削除コマンドをブロック ---
IS_AWS_S3=false
if printf '%s' "$COMMAND" | grep -qE '\baws\s+s3\b'; then IS_AWS_S3=true; fi

if ! is_readonly "$FIRST_CMD" && [ "$IS_AWS_S3" = "false" ]; then
  # フラグは「空白の直後に - で始まるトークン」に限定する。
  # 素の -[a-zA-Z]*r だと job-runner-test のようなハイフン入りパス名の
  # 「-runner」を -r フラグと誤検知する。また [rR] で rm -Rf（大文字R=再帰）も捕捉。
  # セグメント区切りに & を含め、`rm -r x && foo -f` の跨ぎマッチも防ぐ。
  if printf '%s' "$COMMAND" | grep -qE '\brm\b' && \
     printf '%s' "$COMMAND" | grep -qE '\brm\b[^|;&]*[[:space:]]-[a-zA-Z]*[rR]' && \
     printf '%s' "$COMMAND" | grep -qE '\brm\b[^|;&]*[[:space:]]-[a-zA-Z]*f'; then
    deny "rm -rf (再帰的強制削除) は禁止されています"
  fi
  if printf '%s' "$COMMAND" | grep -qE '\brm\b[^|;&]*[[:space:]]--recursive\b.*[[:space:]]--force\b|\brm\b[^|;&]*[[:space:]]--force\b.*[[:space:]]--recursive\b'; then
    deny "rm --recursive --force は禁止されています"
  fi
fi

# ==================================================================
# 新規: 秘密ファイル読み取り検出（ask）— 実在チェック方式
# 読み取り系こそ判定対象なので is_readonly 免除は適用しない。
# ==================================================================
check_bash_read "$COMMAND"

exit 0
