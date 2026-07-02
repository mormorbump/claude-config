# ADR-0001: Claude Code メモリ整理アーキテクチャ

- Status: Accepted
- Date: 2026-07-03

## Context

- ビルトインauto memory (v2.1.59+) は**gitリポジトリ単位で導出され、worktree・サブディレクトリ間で共有**される(マシンローカル)。出典: https://code.claude.com/docs/en/memory 。グローバルCLAUDE.mdの「Worktreeベースだからセッション跨ぎMemoryは使えない」という前提は古い。
- auto memoryは逐次追記型で整理層がなく、放置すると重複・矛盾が蓄積する(コミュニティ実測では20〜30セッションで顕在化)。
- consolidationの設計原則(非破壊・レビュー後採用・重複マージ・死参照除去)は Anthropic Managed Agents の Dreams ( https://platform.claude.com/docs/en/managed-agents/dreams ) およびコミュニティ実装 ( https://github.com/grandamenium/dream-skill ) を参考にした。
- skillsは既に `github.com/mormorbump/claude-skills` でgit管理+Stop hookで自動sync済み(2026-07-03クリーンアップ済み)。グローバルCLAUDE.md / hooks / rules / メモリは未管理。
- 現状のauto memory蓄積はほぼゼロ(実質1件)。**今必要なのは整理(dream)の実行ではなく、受け皿の構造とスキルの整備**。重い仕組みは陳腐化する。

## Decision

### 1. 書き先の分離(各情報の定義箇所は1つ)

| 種類 | 置き場所 | git管理 |
|---|---|---|
| 全プロジェクト共通の行動指示(常時従うもの) | `~/.claude/CLAUDE.md` (200行以下厳守) | ✓ claude-config repo(新設) |
| 共通だが条件付き・詳細な規約 | `~/.claude/rules/*.md` | ✓ 同上 |
| Claude Code環境自体の設計判断 | `~/.claude/adr/` | ✓ 同上 |
| プロジェクト固有ルール | 各repo内 `CLAUDE.md` / `.claude/rules/` | ✓ 各repo |
| プロジェクトの設計判断 | 各repo内 `docs/adr/` | ✓ 各repo |
| 手順・ワークフロー | `~/.claude/skills/` | ✓ 済(既存repo) |
| 変わりうる学習(収集層) | ビルトインauto memory(デフォルト位置のまま) | ✗ 受信箱扱い |

- CLAUDE.mdとrules/の分割基準: **CLAUDE.mdには全セッションで常時従うべき短い行動指示のみ**。条件付き・長文・特定パス向けの規約は `rules/*.md`(必要なら `paths:` frontmatterでスコープ)へ。
- 原則: 同じ内容を2箇所に書かない。auto memoryは「まだ昇格していない知見の受信箱(inbox)」であり、恒久的な正本はすべてgit管理層に置く。

### 2. 整理プロセス = `memory-dream` スキル(手動トリガー)

4フェーズ:

1. **Mine**: 対象プロジェクトのauto memory(`~/.claude/projects/<project>/memory/` のMEMORY.md+トピックファイル)を正として走査。セッショントランスクリプトの走査は必須にしない(重い)。必要時のみサブエージェントで直近数件を要約するオプション扱い。
2. **Consolidate**: 重複マージ、相対日付→絶対日付変換、存在しないファイル/シンボルへの参照を除去。矛盾は原則最新値で解決するが、最新値が一時的workaroundの可能性がある場合は両論併記でレビューに回す。
3. **Promote**: 安定した知見をgit管理層へ昇格。行動指示→CLAUDE.md/rules、プロジェクト知識→repo内docs、繰り返し手順→skill化提案。CLAUDE.mdへの変更は自動適用せずレビュー提案として出す。
4. **Prune & Index**: MEMORY.mdを200行以下のleanなインデックス(1行=リンク+日付+what/why)に再構築し、先頭に `Last dream: YYYY-MM-DD` を記録。詳細はトピックファイルへ。

安全原則:
- 非破壊: git管理層は論理単位でcommit分離しpush保留、auto memory側は変更前にバックアップ。ユーザーレビュー後に採用。
- 成果ファイルに経緯メタ(誰がいつ指摘した、失敗回数、セッションID)を書かない。行動を変える技術的因果(「AだとBが壊れるのでCする」)のみ残す。
- 書き込み対象はメモリ/ドキュメントファイルのみ。コードには触らない。

トリガー(手動。実行判断の材料はスキル自身が残す):
- スキルは実行時にMEMORY.md先頭へ最終実行日を記録し、次回起動時に経過を自己判定して「まだ早い」なら短く報告して終了する(空回り防止)。
- 実行の目安: 月1回 / メモリの矛盾・ノイズに気づいたとき / 大規模リファクタ・移行の直後 / 高性能モデルが期間限定で使えるとき。

### 3. グローバル設定のgit化(claude-config repo)

`~/.claude` をgit repo化し、whitelist方式の.gitignore(全ignore+例外指定)で以下のみtrack:

`CLAUDE.md`, `rules/`, `adr/`, `hooks/`(`*.bak`除く), `scripts/`(ログ類除く), `statusline-command.sh`, `keybindings.json`, `settings.json`

- `skills/` は既存repoのままignore(二重管理しない)。`projects/`(auto memory含む)、キャッシュ、履歴、`settings.local.json` はignore。
- remote: private GitHub repo。
- ~~自動push hookは設けない~~ **改訂(2026-07-03): 複数PC運用の開始に伴い、双方向sync hook(`hooks/sync-config.sh`)を導入**。当初の懸念には次で対処: secretスキャン(commit前に追加行を既知トークンパターンで検査、検出時はcommit中止+通知)、mkdirロックによる多重起動防止、rebase競合時はabort+通知で手動解決。ノイズcommitは許容(skillsと同運用)。
- 既知の限界: user-level MCP設定は `~/.claude.json`(状態データと混在)にあり本設計の対象外。マシン移行時にMCP設定は復元されない。

### 4. 初回移行作業(高性能モデルが使えるうちにやること)

蓄積メモリがほぼゼロの現状では、dreamの初回実行は空振りする。今やる価値があるのは受け皿と道具の整備:

1. claude-config repo化(Section 3)— 機械的作業
2. グローバルCLAUDE.mdの改訂(Section 5)+ 長文化している規約のrules/への再構成
3. **memory-dreamスキルの作成**(Section 2の仕様をSKILL.mdに落とす)— 最も設計力を要するため高性能モデル向き
4. dreamの初回実行はauto memoryが溜まってから(目安: 数週間後)

### 5. グローバルCLAUDE.mdのルール更新

以下2行を1行に統合して書き換える(重複を残さない):

- 削除: 「Memory管理: Worktreeベースでやってるので〜git管理しろ」
- 削除: 「Auto memory: Auto memoryの内容は適切にドキュメント化しろ」
- 追加: 「Memory管理: auto memoryはgitリポジトリ単位でworktree間共有される(マシンローカル)。受信箱扱いとし、恒久知見は /memory-dream でgit管理層(CLAUDE.md / rules / repo docs / skills)へ昇格しろ」

## やらないこと(YAGNI / 陳腐化防止)

- **ナレッジグラフ/オントロジーMCP**: 小規模ではメンテコストがノイズ化(出典記事自身が小規模非推奨)。数百ファイル規模repoで横断クエリが頻発したら再検討。
- **cron/hookによる自動dream**: 現状の活動量では空回りする。ノイズ蓄積を体感してから検討。
- **autoMemoryDirectoryの変更**: 値は絶対パス必須で、repo内配置はworktree毎にパスが割れる。デフォルト(repo単位共有)が既に最適。
- **独自メモリシステムの自作**: ビルトイン仕様に乗る。仕様変更への追従コストを負わない。

## Consequences

- 記憶の階層は実質3つ(ルール / インデックス / トピックファイル)でシンプルに保たれる。
- 恒久知見の正本はすべてgit管理となり、マシン移行・ロールバック・レビューが可能(例外: `~/.claude.json` のMCP設定)。
- 整理は単一スキル+手動トリガーなので、Claude Code本体の仕様変更時に直す箇所が最小。
- スキル整備を高性能モデルで行えば、以後の運用は通常モデルで維持できる。
