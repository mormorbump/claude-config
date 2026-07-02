#!/bin/bash
# ~/.claude (claude-config) を GitHub (origin/main) と双方向同期する
# 呼び出し元: Claude Code Stop hook
# 流れ: secretスキャン → ローカル変更をcommit → fetch+rebaseでリモート取込 → 先行分をpush
# track対象は .gitignore のwhitelistで制御 (ADR-0001 Section 3)
REPO="$HOME/.claude"
LOCK="$HOME/.claude/.config-sync.lock"

cd "$REPO" || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# 多重起動防止（複数セッションの同時Stop対策。10分以上前のロックは残骸として除去）
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
  rmdir "$LOCK" 2>/dev/null
fi
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# 1. ローカル変更をコミット（commit前に追加行をsecretスキャン）
git add -A
if ! git diff --cached --quiet; then
  SECRET_PATTERNS='sk-ant-[A-Za-z0-9_-]{8,}|sk-proj-[A-Za-z0-9_-]{8,}|AIza[0-9A-Za-z_-]{30,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|glpat-[A-Za-z0-9_-]{15,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY'
  if git diff --cached -U0 | grep -E '^\+' | grep -qE "$SECRET_PATTERNS"; then
    git reset -q
    /usr/bin/osascript -e 'display notification "secretらしき文字列を検出したためcommitを中止しました。~/.claude で確認してください" with title "config sync" sound name "Basso"' 2>/dev/null
    echo '{"systemMessage": "config sync: 変更にsecretらしき文字列を検出したためcommitを中止しました。~/.claude で git diff を確認してください。"}'
    exit 0
  fi
  summary=$(git diff --cached --name-status | head -20)
  git commit -q -m "chore: auto-sync config" -m "$summary"
fi

# 2. リモートの変更を取り込み（オフライン等でfetch失敗なら次回に任せる）
if git fetch -q origin main 2>/dev/null; then
  # 履歴リライト（force push）検出: 共通祖先がなければ rebase は必ず壊れるので、
  # ローカルをbackupブランチに退避してリモートへ自動追従する。
  # 未トラックのローカルデータ（metrics/memory/logs等）は reset --hard の影響を受けない
  if ! git merge-base HEAD origin/main >/dev/null 2>&1; then
    backup_branch="backup-before-reset-$(date +%Y%m%d%H%M%S)"
    git branch "$backup_branch" >/dev/null 2>&1
    if git reset --hard origin/main >/dev/null 2>&1; then
      /usr/bin/osascript -e "display notification \"リモート履歴の作り直しを検出し自動追従しました。旧ローカルは ${backup_branch} に退避\" with title \"config sync\"" 2>/dev/null
      echo "{\"systemMessage\": \"config sync: リモートの履歴リライトを検出し origin/main へ自動追従しました。旧ローカル履歴はブランチ ${backup_branch} に退避してあります。\"}"
    else
      /usr/bin/osascript -e 'display notification "履歴リライト追従に失敗しました。~/.claude で手動対応してください" with title "config sync" sound name "Basso"' 2>/dev/null
      echo '{"systemMessage": "config sync: 履歴リライトの自動追従に失敗しました。~/.claude で git status を確認してください。"}'
    fi
    exit 0
  fi
  if ! git rebase -q origin/main >/dev/null 2>&1; then
    git rebase --abort >/dev/null 2>&1
    /usr/bin/osascript -e 'display notification "競合が発生しました。~/.claude で手動解決してください" with title "config sync" sound name "Basso"' 2>/dev/null
    echo '{"systemMessage": "config sync: rebase競合が発生しました。~/.claude で手動解決してください。"}'
    exit 0
  fi
else
  exit 0
fi

# 3. ローカルが先行していればpush
if [ -n "$(git log origin/main..HEAD --oneline 2>/dev/null)" ]; then
  if ! git push -q origin main >/dev/null 2>&1; then
    echo '{"systemMessage": "config sync: pushに失敗しました。後で ~/.claude で git push してください。"}'
  fi
fi
exit 0
