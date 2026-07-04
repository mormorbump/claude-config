#!/bin/bash
# 現在の Claude Code セッション ID を stdout に出力する（compact-prep skill 用）
# 解決順:
#   1. $CLAUDE_SESSION_ID 環境変数
#   2. プロセス祖先を辿って claude 本体 PID を特定 → session-map を読む
#      (map は userpromptsubmit-session-map.sh hook が毎プロンプト書いている)
#   3. cwd に対応する ~/.claude/projects/<slug>/ の最新 transcript ファイル名
# どれも失敗したら何も出力せず exit 1（呼び出し側の Hard gate で停止させる）

set -uo pipefail

if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
  printf '%s\n' "$CLAUDE_SESSION_ID"
  exit 0
fi

# 2. プロセス祖先 → session-map
MAP_DIR="${TMPDIR:-/tmp}/claude-session-map"
pid=$$
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  case "$pid" in ''|0|1) break ;; esac
  if [ -f "$MAP_DIR/$pid" ]; then
    cat "$MAP_DIR/$pid"
    exit 0
  fi
done

# 3. fallback: cwd の project dir で最も新しい transcript
slug=$(pwd | sed 's#[/.]#-#g')
latest=$(ls -t "$HOME/.claude/projects/$slug/"*.jsonl 2>/dev/null | head -1)
if [ -n "$latest" ]; then
  basename "$latest" .jsonl
  exit 0
fi

exit 1
