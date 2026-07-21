#!/bin/bash
# Claude Code on the web 用ブートストラップ（ADR-0010）
# クラウドコンテナには ~/.claude のグローバル資産（skills等）が存在しないため、
# repo として clone された claude-config 側から補う。
# hook はローカル・クラウド両方で走る仕様なので、CLAUDE_CODE_REMOTE で即分岐する。
set -u

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
SKILLS_DIR="$PROJECT_DIR/.claude/skills"

emit() {
  # $1: reloadSkills (true/false), $2: additionalContext（"や\を含めないこと）
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","reloadSkills":%s,"additionalContext":"%s"}}\n' "$1" "$2"
}

if [ ! -d "$SKILLS_DIR/.git" ]; then
  if ! git clone --depth 1 https://github.com/mormorbump/claude-skills.git "$SKILLS_DIR" >/dev/null 2>&1; then
    emit false "[session-start] claude-skills(private) の clone に失敗。GitHub 認証のrepoアクセス範囲を確認すること。スキルなしで続行する。"
    exit 0
  fi
fi

emit true "[session-start] claude-skills を .claude/skills に配置済み（cloud bootstrap, ADR-0010）"
