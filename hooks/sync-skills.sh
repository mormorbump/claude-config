#!/bin/bash
# ~/.claude/skills を GitHub (origin/main) と双方向同期する
# 呼び出し元: Claude Code Stop hook / launchd (com.mormorbump.claude-skills-sync)
# 流れ: ローカル変更をcommit → fetch+rebaseでリモート取込 → 先行分をpush
REPO="$HOME/.claude/skills"
LOCK="$HOME/.claude/.skills-sync.lock"

cd "$REPO" || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# 多重起動防止（Stop hookとlaunchdの同時実行対策。10分以上前のロックは残骸として除去）
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
  rmdir "$LOCK" 2>/dev/null
fi
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# 1. ローカル変更をコミット
git add -A
if ! git diff --cached --quiet; then
  summary=$(git diff --cached --name-status | head -20)
  git commit -q -m "chore: auto-sync skills" -m "$summary"
fi

# 2. リモートの変更を取り込み（オフライン等でfetch失敗なら次回に任せる）
if git fetch -q origin main 2>/dev/null; then
  if ! git rebase -q origin/main >/dev/null 2>&1; then
    git rebase --abort >/dev/null 2>&1
    /usr/bin/osascript -e 'display notification "競合が発生しました。~/.claude/skills で手動解決してください" with title "skills sync" sound name "Basso"' 2>/dev/null
    echo '{"systemMessage": "skills sync: rebase競合が発生しました。~/.claude/skills で手動解決してください。"}'
    exit 0
  fi
else
  exit 0
fi

# 3. ローカルが先行していればpush
if [ -n "$(git log origin/main..HEAD --oneline 2>/dev/null)" ]; then
  if ! git push -q origin main >/dev/null 2>&1; then
    echo '{"systemMessage": "skills sync: pushに失敗しました。後で ~/.claude/skills で git push してください。"}'
  fi
fi
exit 0
