# ADR-0008: /memory-dream 実行メトリクスとstatusモード

- Status: Accepted
- Date: 2026-07-08

## Context

- `/memory-dream` は実行のたびに「昇格/統合/削除の件数」を会話に報告するが、どこにも永続化されない。前回実行日・累計昇格数・eval合否の推移・「スキル化提案が実際に作られたか」が事後に一切参照できず、フィードバックループが機能しているか外部から検証できない。
- 一方で「昇格ルールが後続セッションで実際に守られたか」のような真の効果測定は、セッショントランスクリプト横断解析が必要で、ADR-0001が明示的に避けている重い仕組みになる。今回は範囲外とする。

## Decision

### 1. 実行ログ(`~/.claude/dream-log/DREAM_LOG.md`)

- 追記専用のmarkdownテーブル。1実行=1行。列: `Date, Scope, Mined, Consolidated, Promoted, Pruned, EvalsRun, EvalsPass, EvalsFail, EvalsCreated, SkillProposals`。
- `SkillProposals` は今回「skill化を提案」した候補名をカンマ区切りで記録(実際に作るかはユーザー判断のため、提案止まり)。
- git管理(claude-config repo)。EVAL_INDEX.mdと同じ「テーブルで足りる、DB/グラフは作らない」思想。

### 2. statusモード(読み取り専用、既存フローを実行しない)

- `/memory-dream status`(または「メモリ整理の状況を教えて」「dreamのメトリクス」等の自然文)で起動。
- `DREAM_LOG.md` の直近実行群 + 全scopeの `EVAL_INDEX.md` を読み、以下を報告する:
  - 最終実行日、累計実行回数、累計昇格件数
  - 直近実行のeval合否件数と、その前回実行との比較(悪化/改善/横ばい)
  - 現在failしているevalの一覧(要対応)
  - 過去の `SkillProposals` のうち、`~/.claude/skills/<name>/SKILL.md` がまだ存在しないもの(＝提案止まりで未着手)
- 通常実行フロー(Mine〜Prune)は一切走らせない。ファイル変更もしない。

### 3. 明示的にやらないこと

- セッショントランスクリプトを解析した「実際の遵守率」測定
- 昇格ルールごとの個別履歴保持(現状は実行単位の集計のみ。個別ルールの時系列が要る規模になったら再検討)
- 自動アラート・通知の仕組み(statusは呼ばれた時に答えるだけ)

## Consequences

- 実行のたびにDREAM_LOG.mdへ1行追記するコストのみで、フィードバックループの健全性を後から検証できるようになる。
- 「スキル化提案が放置されている」ことが可視化され、compact-plus的な放置ノイズを防ぐ。
