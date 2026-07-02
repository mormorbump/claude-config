#!/bin/bash
# metrics.sh が出力した ~/.claude/metrics/usage-*.jsonl を集計してレポート表示する
# 使い方: metrics-report.sh [days]  (省略時 7日)
set -uo pipefail

DAYS="${1:-7}"
METRICS_DIR="$HOME/.claude/metrics"

case "$DAYS" in
  ''|*[!0-9]*) DAYS=7 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  echo "エラー: jq が見つかりません。"
  exit 0
fi

# 日数分前の日付を YYYY-MM-DD で算出（macOS date）
THRESHOLD="$(date -u -v-"${DAYS}"d +%Y-%m-%d 2>/dev/null)"
if [ -z "$THRESHOLD" ]; then
  # -v が使えない環境向けフォールバック（GNU date想定だが基本macOSのみサポート）
  THRESHOLD="$(date -u -d "-${DAYS} days" +%Y-%m-%d 2>/dev/null)"
fi
if [ -z "$THRESHOLD" ]; then
  echo "エラー: 日付計算に失敗しました。"
  exit 0
fi

shopt -s nullglob 2>/dev/null
FILES=("$METRICS_DIR"/usage-*.jsonl)

if [ ! -d "$METRICS_DIR" ] || [ ${#FILES[@]} -eq 0 ]; then
  echo "=== Metrics Report (直近 ${DAYS} 日) ==="
  echo "データなし（${METRICS_DIR} に usage-*.jsonl が見つかりません）"
  exit 0
fi

TMP_DIR="$HOME/.claude/.context"
mkdir -p "$TMP_DIR" 2>/dev/null
TMP_JSONL="$(mktemp "${TMP_DIR}/metrics-report.XXXXXX" 2>/dev/null)"
if [ -z "$TMP_JSONL" ]; then
  echo "エラー: 一時ファイルの作成に失敗しました。"
  exit 0
fi
trap 'rm -f "$TMP_JSONL"' EXIT

# 対象ファイルを結合し、ts >= THRESHOLD の行だけを抽出（壊れた行はスキップ）
for f in "${FILES[@]}"; do
  [ -r "$f" ] || continue
  cat "$f" 2>/dev/null
done | jq -c --arg th "$THRESHOLD" '
  select(type == "object")
  | select((.ts // "") != "")
  | select((.ts | .[0:10]) >= $th)
' 2>/dev/null > "$TMP_JSONL" || true

RECORD_COUNT="$(wc -l < "$TMP_JSONL" 2>/dev/null | tr -d ' ')"
RECORD_COUNT="${RECORD_COUNT:-0}"

echo "=== Metrics Report (直近 ${DAYS} 日 / ${THRESHOLD} 以降 / ${RECORD_COUNT}件) ==="
echo

if [ "$RECORD_COUNT" -eq 0 ] 2>/dev/null; then
  echo "データなし"
  exit 0
fi

echo "--- ツール別回数 Top10 ---"
RESULT="$(jq -r '.tool_name // empty' "$TMP_JSONL" 2>/dev/null | sort | uniq -c | sort -rn | head -10)"
if [ -n "$RESULT" ]; then
  printf '%s\n' "$RESULT" | awk '{cnt=$1; $1=""; printf "  %-30s %s\n", substr($0,2), cnt}'
else
  echo "  データなし"
fi
echo

echo "--- スキル別回数 ---"
RESULT="$(jq -r '.skill? // empty' "$TMP_JSONL" 2>/dev/null | sort | uniq -c | sort -rn)"
if [ -n "$RESULT" ]; then
  printf '%s\n' "$RESULT" | awk '{cnt=$1; $1=""; printf "  %-30s %s\n", substr($0,2), cnt}'
else
  echo "  データなし"
fi
echo

echo "--- サブエージェント種別回数 ---"
RESULT="$(jq -r '.subagent_type? // empty' "$TMP_JSONL" 2>/dev/null | sort | uniq -c | sort -rn)"
if [ -n "$RESULT" ]; then
  printf '%s\n' "$RESULT" | awk '{cnt=$1; $1=""; printf "  %-30s %s\n", substr($0,2), cnt}'
else
  echo "  データなし"
fi
echo

echo "--- プロジェクト(cwd)別回数 Top10 ---"
RESULT="$(jq -r '.cwd? // empty' "$TMP_JSONL" 2>/dev/null | sort | uniq -c | sort -rn | head -10)"
if [ -n "$RESULT" ]; then
  printf '%s\n' "$RESULT" | awk '{cnt=$1; $1=""; printf "  %-40s %s\n", substr($0,2), cnt}'
else
  echo "  データなし"
fi
echo

echo "--- 日別合計 ---"
RESULT="$(jq -r '.ts? | select(. != null) | .[0:10]' "$TMP_JSONL" 2>/dev/null | sort | uniq -c | sort -k2)"
if [ -n "$RESULT" ]; then
  printf '%s\n' "$RESULT" | awk '{cnt=$1; $1=""; printf "  %-15s %s\n", substr($0,2), cnt}'
else
  echo "  データなし"
fi

exit 0
