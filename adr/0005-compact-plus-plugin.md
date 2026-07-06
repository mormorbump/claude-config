# ADR-0005: compact-plus plugin 採用（ADR-0004 の自前実装を縮退）

Date: 2026-07-07
Status: Accepted (ADR-0004 を supersede)

## 背景

ADR-0004 の自前実装は「PreCompact はシェルのみ＝モデルに state を書かせられない」前提で、手動 `/compact-prep` + 60%通知で auto compact に先回りする設計だった。参考記事の作者が **PreCompact hook 内から headless LLM（`claude -p`、fallback は `codex exec`）を呼ぶ**ことでこの制約を突破し、plugin 化した（[u-ichi/compact-plus](https://github.com/u-ichi/compact-plus)）。manual/auto 両方の compact 直前に構造化 state file が透過的に自動生成されるため、自前実装最大の穴（auto compact 時は state が保存されない）が塞がる。

## 決定

compact-plus plugin（GitHub marketplace 経由、`extraKnownMarketplaces` で全PCに同期）を採用し、自前実装の重複部分を撤去した。

### 撤去したもの（plugin が代替）

- `hooks/compaction-recovery.sh`（PostCompact marker）
- `hooks/userpromptsubmit-compaction-recovery.sh`（復旧注入）
- `hooks/userpromptsubmit-compact-prep-reminder.sh`（60%通知注入）
- `skills/compact-prep/`（→ plugin の `/compact-plus` skill。見出しに `## Skills Invoked` / `## Failed Attempts` が追加されている）
- settings.json の該当 hook 登録

### 残したもの（plugin が所有しない producer / 前提インフラ）

- `statusline-command.sh` の 60% warn marker producer（`COMPACT_WARN_THRESHOLD=60`）。plugin docs も「statusline hook は base repository 所有、plugin は marker を読むだけ」と明記
- `hooks/userpromptsubmit-session-map.sh` + `scripts/get-session-id.sh`。**plugin の `/compact-plus` skill が手順1で `~/.claude/scripts/get-session-id.sh` を参照する**ため必須の前提インフラ。map の自己掃除（7日）は session-map hook 内に移動

### marker パスは plugin 規約（`${TMPDIR:-/tmp}`）に統一

ADR-0004 で `~/.claude/tmp/` に移したが、plugin は TMPDIR 固定でパス上書き env がない。producer（statusline）が別の場所に書くと plugin の reminder が発火しないため、statusline を TMPDIR に戻した。ADR-0004 当時の懸念は以下で緩和済みと判断:

- state file は compact サイクル内で消費される短命データ（macOS の3日掃除に実質かからない）
- transcript 全文が `~/.claude/backups/transcripts/` に永続バックアップされ、state が消えても復旧材料は残る

グローバルルール「/tmp に一時ファイルを作るな」には、hook/plugin 間で受け渡すインフラ marker を例外とする注記を CLAUDE.md に追加。state dir の env 化は upstream への提案余地あり。

## 運用ノート

- PreCompact のたびに `claude -p --model claude-sonnet-5`（既定）が走る。コストが気になれば `COMPACT_PLUS_PRIMARY_BACKEND` で差し替え（settings.json の env）
- PreCompact hook の timeout は 180s。compact がその分遅くなる
- 60% は 1M context 前提の閾値。200K セッション主体なら statusline の `COMPACT_WARN_THRESHOLD` を 75-80 へ
- 検証: `hooks/tests/test-compact-hooks.sh`（statusline → plugin hook の marker 受け渡しを実 plugin で統合テスト、13 assertions）
