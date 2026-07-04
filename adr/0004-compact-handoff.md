# ADR-0004: compact 前後の引き継ぎ機構（compact-prep + marker hooks + 60%通知）

Date: 2026-07-04
Status: Accepted

## 背景

Claude Code の compact（手動/自動）は会話履歴をLLM要約に置き換えるため、「なぜ却下したか」「今どのフェーズか」等の判断構造とセッション状態が落ちる。圧縮直後に却下案の再実行・検証スキップ・タスク目的の取り違えが構造的に発生する。参考記事の設計をそのまま採用した。

## 決定

3パーツ構成。hook間の通信は `${TMPDIR:-/tmp}` 配下の marker file のみ（Claude Codeにhook間状態共有機構がないため）。全hookは fail-open（常に exit 0）。

### 1. compact-prep skill（`~/.claude/skills/compact-prep/`）

`/compact` 前にユーザーが叩く。要約に載りにくい判断構造・セッション状態を
`${TMPDIR}/claude-compact-state/<session_id>.md` に固定フォーマットで保存する。
session_id が取れなければ推測名で作らず停止（Hard gate）。

### 2. 圧縮復旧の2段 hook

- `hooks/compaction-recovery.sh`（PostCompact）: 圧縮発生を marker `claude-compacted/<sid>` に記録。PostCompact は additionalContext 非対応のため記録のみ
- `hooks/userpromptsubmit-compaction-recovery.sh`（UserPromptSubmit）: marker 検出時に one-shot で復旧指示（state file を読め / 圧縮サマリーの next step は仮説扱い等）を additionalContext 注入

### 3. 60% 通知（自動compactの先回り）

自動compactは宣言なしに走り skill を挟めないため、閾値到達で手動 `/compact-prep` → `/compact` を促す。

- `statusline-command.sh`: `context_window.used_percentage >= 60` で warn marker 書込（cooldown 中は抑止）
- `hooks/userpromptsubmit-compact-prep-reminder.sh`: warn marker 検出で「compact-prep を提案せよ」を注入し、cooldown marker `claude-compact-warned/<sid>` を作成。cooldown は PostCompact でリセット

閾値は `statusline-command.sh` の `COMPACT_WARN_THRESHOLD=60`。60% は 1M context 前提の数字。200K context で窮屈なら 75〜80 に上げる。

### 補助: session_id 解決（記事にない独自部分）

skill の Bash から session_id を知る公式手段がないため:

- `hooks/userpromptsubmit-session-map.sh`: 毎プロンプト、プロセス祖先から claude 本体 PID を特定し `claude-session-map/<claude_pid>` に session_id を記録
- `scripts/get-session-id.sh`: `$CLAUDE_SESSION_ID` → 祖先PID→map → cwd の最新 transcript、の順で解決

## marker 一覧

| marker dir | 書く | 消す | 意味 |
|---|---|---|---|
| claude-compact-warn | statusline | reminder hook | 通知したい |
| claude-compact-warned | reminder hook | PostCompact hook | 通知済み cooldown |
| claude-compacted | PostCompact hook | recovery hook | 圧縮直後 |
| claude-session-map | session-map hook | (残置、reboot で消滅) | PID→session_id |
| claude-compact-state | compact-prep skill | (残置) | 引き継ぎ本体 |

## 却下した代替案

- SessionStart(matcher: compact) での直接注入: additionalContext 対応だが、記事の PostCompact + UserPromptSubmit 構成を採用（ユーザー指定でそのまま移植。marker 方式は plan pointer 等の拡張と共通機構になる）
- PreCompact での手動 compact ブロック（stale handoff 時に弾く）: /compact の UX を全プロジェクトで変えるため見送り

## テスト

`hooks/tests/test-compact-hooks.sh`（TMPDIR 隔離、17 assertions）
