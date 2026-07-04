#!/bin/bash
# UserPromptSubmit hook: claude 本体プロセスの PID → session_id の対応を書く。
# compact-prep skill の get-session-id.sh がプロセス祖先を辿ってこの map を読む。
# fail-open (常に exit 0)

set -uo pipefail

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && exit 0

CLAUDE_TMP_BASE="${CLAUDE_TMP_BASE:-$HOME/.claude/tmp}"
MAP_DIR="$CLAUDE_TMP_BASE/claude-session-map"
mkdir -p "$MAP_DIR" 2>/dev/null || true

# 祖先を辿って claude 本体プロセスを探し、その PID をキーに session_id を記録
pid=$$
for _ in 1 2 3 4 5 6 7 8 9 10; do
  ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  case "$ppid" in ''|0|1) break ;; esac
  cmd=$(ps -o command= -p "$ppid" 2>/dev/null)
  case "$cmd" in
    *claude*)
      printf '%s\n' "$SESSION_ID" > "$MAP_DIR/$ppid" 2>/dev/null || true
      break
      ;;
  esac
  pid=$ppid
done

exit 0
