#!/bin/bash
# compact 引き継ぎ機構のテスト (ADR-0005: compact-plus plugin 採用後の構成)
# 自前で持つのは statusline の warn marker producer と session-map/get-session-id のみ。
# marker 消費側は compact-plus plugin。ここでは両者のパス規約が噛み合うことを統合検証する。
# 実行: bash ~/.claude/hooks/tests/test-compact-hooks.sh

HOOKS="$HOME/.claude/hooks"
PLUGIN_HOOKS=$(ls -d "$HOME/.claude/plugins/cache/compact-plus-local/compact-plus/"*/hooks 2>/dev/null | sort | tail -1)
SANDBOX=$(mktemp -d)
# statusline は CLAUDE_TMP_BASE、plugin は TMPDIR を見る。両方を sandbox に向ける
export CLAUDE_TMP_BASE="$SANDBOX"
export TMPDIR="$SANDBOX/"
SID="test-session-0001"
PASS=0; FAIL=0

check() { # check <desc> <condition...>
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); echo "ok: $desc"
  else FAIL=$((FAIL+1)); echo "NG: $desc"; fi
}

check "plugin: compact-plus の hooks が配備されている" test -n "$PLUGIN_HOOKS"

# --- 1. statusline: 閾値超で warn marker を書く ---
SL_INPUT="{\"session_id\":\"$SID\",\"model\":{\"id\":\"m\"},\"workspace\":{\"current_dir\":\"$HOME\"},\"context_window\":{\"used_percentage\":63}}"
echo "$SL_INPUT" | bash "$HOME/.claude/statusline-command.sh" >/dev/null
check "statusline: 63% で warn marker が作成される" test -f "$SANDBOX/claude-compact-warn/$SID"
check "statusline: marker に使用率が記録される" grep -q "63" "$SANDBOX/claude-compact-warn/$SID"

# --- 2. plugin reminder hook が statusline の marker を消費できる（パス規約の統合検証） ---
if [ -n "$PLUGIN_HOOKS" ]; then
  OUT=$(echo "{\"session_id\":\"$SID\"}" | bash "$PLUGIN_HOOKS/userpromptsubmit-compact-plus-reminder.sh")
  check "interop: plugin reminder が注入を出力する" test -n "$OUT"
  echo "$OUT" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1
  check "interop: 出力が valid JSON (additionalContext)" test $? -eq 0
  check "interop: warn marker が消費される (one-shot)" test ! -f "$SANDBOX/claude-compact-warn/$SID"
  check "interop: warned marker (cooldown) が作成される" test -f "$SANDBOX/claude-compact-warned/$SID"

  # --- 3. plugin PostCompact が cooldown をリセットし recovery marker を書く ---
  echo "{\"session_id\":\"$SID\"}" | bash "$PLUGIN_HOOKS/compaction-recovery.sh"
  check "plugin: PostCompact で compacted marker が作成される" test -f "$SANDBOX/claude-compacted/$SID"
  check "plugin: PostCompact で warned cooldown がリセットされる" test ! -f "$SANDBOX/claude-compact-warned/$SID"
fi

# --- 4. statusline: cooldown 中は warn marker を再作成しない ---
mkdir -p "$SANDBOX/claude-compact-warned"; touch "$SANDBOX/claude-compact-warned/$SID"
echo "$SL_INPUT" | bash "$HOME/.claude/statusline-command.sh" >/dev/null
check "statusline: cooldown 中は再通知しない" test ! -f "$SANDBOX/claude-compact-warn/$SID"

# --- 5. statusline: 閾値未満では書かない ---
rm -f "$SANDBOX/claude-compact-warned/$SID"
SL_LOW="{\"session_id\":\"$SID\",\"model\":{\"id\":\"m\"},\"workspace\":{\"current_dir\":\"$HOME\"},\"context_window\":{\"used_percentage\":42}}"
echo "$SL_LOW" | bash "$HOME/.claude/statusline-command.sh" >/dev/null
check "statusline: 42% では warn marker を書かない" test ! -f "$SANDBOX/claude-compact-warn/$SID"

# --- 6. get-session-id.sh / session-map hook (plugin skill の前提インフラ) ---
OUT=$(CLAUDE_SESSION_ID="env-sess" "$HOME/.claude/scripts/get-session-id.sh")
check "get-session-id: CLAUDE_SESSION_ID を優先する" test "$OUT" = "env-sess"
echo '{}' | "$HOOKS/userpromptsubmit-session-map.sh"
check "session-map: session_id なしでも exit 0" test $? -eq 0

rm -f "$SANDBOX"/claude-*/* 2>/dev/null
rmdir "$SANDBOX"/claude-* "$SANDBOX" 2>/dev/null
echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
