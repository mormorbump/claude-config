# ADR-0009: /memory-dream と knowledge-extract の役割境界、Obsidian昇格の扱い

- Status: Accepted
- Date: 2026-07-08

## Context

- Obsidian PermanentNoteへの知見昇格は既に `scripts/jobs/prompts/knowledge-extract.md`（`run-job.sh` 経由でlaunchdが平日9:00に無人実行）が担っている。収集元は auto memory ではなく直近26時間の生セッションtranscript。「一般化可能な原理」「文脈を知らない人間が単体で読んで学びになる」の両方を満たす場合のみ、高いバー(「迷ったら書かない」)でVaultへ書く。
- `/memory-dream`(このADR群)は、knowledge-extractが既にmemory受信箱へ書いた知見(および会話中に蓄積された知見)を人間の判断でgit管理層(CLAUDE.md/rules/skills/docs)へ昇格するHITLフロー。両者の役割分担はclaude-config repo READMEに明記済み: knowledge-extract=候補の自動掘り起こし、/memory-dream=人間の重要判定による昇格。
- ADR-0007設計時、この既存パイプラインを見落とし、Obsidianを昇格先候補から漏らしていた。knowledge-extractが見送った(または保守的すぎた)知見を、後からConsolidateフェーズで人間が「実は一般化できる」と気づくケースの受け皿がない。

## Decision

### 1. Obsidian昇格ロジックの単一情報源

- 「何がObsidian行きの基準を満たすか」の判定基準・frontmatter形式・タグ規則は `scripts/jobs/prompts/knowledge-extract.md` を正とする。`/memory-dream` はこの基準を複製せず参照する。
- 基準(再掲、判定はこれをすべて満たす場合のみ):
  - プロジェクト・環境・Claude固有ではなく一般化可能な原理・判断軸
  - セッション文脈を知らない人間が単体で読んで学びになる
  - 「なぜそうなるか」の抽象化ができている(具体的手順の羅列ではない)
  - 対象外: Claude向け行動修正(feedback型)、特定repoの手順、環境設定メモ

### 2. /memory-dreamのPromote先にObsidian PermanentNoteを追加(補完的・低頻度想定)

- 対象: auto memory中の `metadata.type: user | reference` のエントリ、またはConsolidateで複数断片を統合した結果、上記基準を満たすと判断できたもの。CLAUDE.md/rules/skills/docsのいずれにも当てはまらない「個人的なドメイン知識」の受け皿。
- 書き込み形式・パス・タグ規則・PIIガードは `knowledge-extract.md` の「6. PermanentNoteへの昇格」節と完全に同一のものを使う(frontmatter: `createdAt, tags, source, originSessionId`。ただし `source` はこの経路では `memory-dream` とする)。
- 事前に対象ディレクトリを `ls` して同主題の既存ノートがないか確認し、あれば新規作成せずスキップ(knowledge-extractの重複防止ルールを踏襲)。
- **想定頻度は低い**。knowledge-extractが既に大半をカバーするため、/memory-dream側での新規Obsidian昇格は「見送られていたものの拾い上げ」に限られる。0件が普通という基準もそのまま引き継ぐ。

## やらないこと

- /memory-dream独自のObsidian判定ロジックの新規開発(knowledge-extractの基準を流用するだけ)
- knowledge-extract側のロジック変更(このADRは/memory-dream側の変更のみ)

## Consequences

- Obsidian昇格の基準が1箇所(`knowledge-extract.md`)に集約され、2つの昇格経路が矛盾した基準で動くリスクがなくなる。
- 個人的ドメイン知識がCLAUDE.md/rules/skills/docsのどれにも当てはまらず宙に浮く/黙って削除される問題が解消される。
