#!/bin/bash
# install-launchd.sh — knowledge-extract launchd job を冪等に反映する
# Usage: install-launchd.sh
#
# 既存のロード済みジョブを一旦bootoutしてから、plistをコピーしてbootstrapし直す。
# 何度実行しても同じ結果になる（冪等）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.claude.job-knowledge-extract"
PLIST_SRC="${SCRIPT_DIR}/launchd/${LABEL}.plist"
PLIST_DST="$HOME/Library/LaunchAgents/${LABEL}.plist"

if [[ ! -f "$PLIST_SRC" ]]; then
  echo "ERROR: plist not found: $PLIST_SRC" >&2
  exit 1
fi

UID_NUM="$(id -u)"

echo "Unloading existing job (if any): ${LABEL}"
launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true

echo "Generating plist: ${PLIST_SRC} -> ${PLIST_DST}"
mkdir -p "$HOME/Library/LaunchAgents"
# launchd は StandardOut/ErrPath のディレクトリを作成しないため事前に用意する
mkdir -p "$HOME/.claude/scripts/logs/jobs"
# テンプレートの __HOME__ を実際の $HOME に置換して配置
# （launchd は plist 内の ~ や環境変数を展開しないため、インストール時に絶対パス化する）
sed "s|__HOME__|${HOME}|g" "$PLIST_SRC" > "$PLIST_DST"
plutil -lint "$PLIST_DST" >/dev/null || { echo "ERROR: generated plist failed lint" >&2; exit 1; }

echo "Bootstrapping job: ${LABEL}"
launchctl bootstrap "gui/${UID_NUM}" "$PLIST_DST"

echo "Done. Verify with: launchctl print gui/${UID_NUM}/${LABEL}"
