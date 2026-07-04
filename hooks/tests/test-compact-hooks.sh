#!/bin/bash
# compact 引き継ぎ機構 (compact-prep / 60%通知 / 圧縮復旧) のテスト
# marker の読み書きを CLAUDE_TMP_BASE 隔離で検証する
# 実行: bash ~/.claude/hooks/tests/test-compact-hooks.sh

HOOKS="$HOME/.claude/hooks"
SANDBOX=$(mktemp -d)
export CLAUDE_TMP_BASE="$SANDBOX"
SID="test-session-0001"
PASS=0; FAIL=0

check() { # check <desc> <condition...>
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); echo "ok: $desc"
  else FAIL=$((FAIL+1)); echo "NG: $desc"; fi
}

# --- 1. PostCompact: compaction-recovery.sh ---
mkdir -p "$SANDBOX/claude-compact-warned"
touch "$SANDBOX/claude-compact-warned/$SID"
echo "{\"session_id\":\"$SID\"}" | "$HOOKS/compaction-recovery.sh"
check "PostCompact: compacted marker が作成される" test -f "$SANDBOX/claude-compacted/$SID"
check "PostCompact: warned marker (cooldown) がリセットされる" test ! -f "$SANDBOX/claude-compact-warned/$SID"

# --- 2. UserPromptSubmit: compaction-recovery (marker あり + state file あり) ---
mkdir -p "$SANDBOX/claude-compact-state"
echo "# Compact Prep State" > "$SANDBOX/claude-compact-state/$SID.md"
OUT=$(echo "{\"session_id\":\"$SID\"}" | "$HOOKS/userpromptsubmit-compaction-recovery.sh")
check "recovery: additionalContext を出力する" grep -q "COMPACTION RECOVERY" <<<"$OUT"
check "recovery: state file のパスを含む" grep -q "claude-compact-state/$SID.md" <<<"$OUT"
echo "$OUT" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1
check "recovery: 出力が valid JSON" test $? -eq 0
check "recovery: marker が削除される (one-shot)" test ! -f "$SANDBOX/claude-compacted/$SID"

# --- 3. UserPromptSubmit: compaction-recovery (marker なし → 即 exit) ---
OUT=$(echo "{\"session_id\":\"$SID\"}" | "$HOOKS/userpromptsubmit-compaction-recovery.sh")
check "recovery: marker なしでは何も出力しない" test -z "$OUT"

# --- 4. statusline: 閾値超で warn marker を書く ---
SL_INPUT="{\"session_id\":\"$SID\",\"model\":{\"id\":\"m\"},\"workspace\":{\"current_dir\":\"$HOME\"},\"context_window\":{\"used_percentage\":63}}"
echo "$SL_INPUT" | bash "$HOME/.claude/statusline-command.sh" >/dev/null
check "statusline: 63% で warn marker が作成される" test -f "$SANDBOX/claude-compact-warn/$SID"
check "statusline: marker に使用率が記録される" grep -q "63" "$SANDBOX/claude-compact-warn/$SID"

# --- 5. UserPromptSubmit: compact-prep-reminder ---
OUT=$(echo "{\"session_id\":\"$SID\"}" | "$HOOKS/userpromptsubmit-compact-prep-reminder.sh")
check "reminder: 使用率入りの注入を出力する" grep -q "63%" <<<"$OUT"
check "reminder: compact-prep を提案させる" grep -q "compact-prep" <<<"$OUT"
check "reminder: warn marker が削除される (one-shot)" test ! -f "$SANDBOX/claude-compact-warn/$SID"
check "reminder: warned marker (cooldown) が作成される" test -f "$SANDBOX/claude-compact-warned/$SID"

# --- 6. statusline: cooldown 中は warn marker を再作成しない ---
echo "$SL_INPUT" | bash "$HOME/.claude/statusline-command.sh" >/dev/null
check "statusline: cooldown 中は再通知しない" test ! -f "$SANDBOX/claude-compact-warn/$SID"

# --- 7. statusline: 閾値未満では書かない ---
rm -f "$SANDBOX/claude-compact-warned/$SID"
SL_LOW="{\"session_id\":\"$SID\",\"model\":{\"id\":\"m\"},\"workspace\":{\"current_dir\":\"$HOME\"},\"context_window\":{\"used_percentage\":42}}"
echo "$SL_LOW" | bash "$HOME/.claude/statusline-command.sh" >/dev/null
check "statusline: 42% では warn marker を書かない" test ! -f "$SANDBOX/claude-compact-warn/$SID"

# --- 8. get-session-id.sh: env 変数経由 ---
OUT=$(CLAUDE_SESSION_ID="env-sess" "$HOME/.claude/scripts/get-session-id.sh")
check "get-session-id: CLAUDE_SESSION_ID を優先する" test "$OUT" = "env-sess"

# --- 9. session-map hook: fail-open (session_id なし) ---
echo '{}' | "$HOOKS/userpromptsubmit-session-map.sh"
check "session-map: session_id なしでも exit 0" test $? -eq 0

rm -rf "$SANDBOX"
echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
