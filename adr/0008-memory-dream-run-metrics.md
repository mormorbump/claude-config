# ADR-0008: /memory-dream 実行メトリクスとstatusモード

- Status: Accepted
- Date: 2026-07-08

## Context

- `/memory-dream` は実行のたびに「昇格/統合/削除の件数」を会話に報告するが、どこにも永続化されない。前回実行日・累計昇格数・eval合否の推移・「スキル化提案が実際に作られたか」が事後に一切参照できず、フィードバックループが機能しているか外部から検証できない。
- 一方で「昇格ルールが後続セッションで実際に守られたか」のような真の効果測定は、セッショントランスクリプト横断解析が必要で、ADR-0001が明示的に避けている重い仕組みになる。今回は範囲外とする。

## Decision

### 1. 実行ログ(`~/.claude/metrics/dream.jsonl`)

- 追記専用のJSONL。1実行=1行:

```json
{"ts":"2026-07-08T12:00:00Z","scope":"-Users-matsumotokazuki","mined":5,"consolidated":3,"promoted":2,"pruned":4,"evals_run":3,"evals_pass":3,"evals_fail":0,"evals_created":1,"skill_proposals":["foo-workflow"]}
```

- `skill_proposals` は今回「skill化を提案」した候補名の配列(実際に作るかはユーザー判断のため、提案止まり)。
- 追記はスキル実行中のClaudeが行う(専用hookは作らない)。mined/promoted等の件数はモデル自身にしか分からない自己申告値であり、hookで決定的に取れるものではない。eval合否のみ実コマンド実行の結果。
- 置き場所は既存の `jobs-YYYY-MM.jsonl` と同じmetrics層 = **マシンローカル・git非同期**(ADR-0006、READMEの「ローカル層」)。auto memory自体がマシンローカルなので、その整理履歴もマシンローカルが整合的。実行頻度が低いため月次分割せず単一ファイル。
- 人間はこのJSONLを直接読まない。読むためのビューがstatusモード(下記)。

### 2. statusモード(読み取り専用、既存フローを実行しない)

- `/memory-dream status`(または「メモリ整理の状況を教えて」「dreamのメトリクス」等の自然文)で起動。
- `~/.claude/metrics/dream.jsonl` + 全scopeの `EVAL_INDEX.md` を読み、人間が読みやすい形(要約+小さなテーブル)に整形して以下を報告する:
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

- 実行のたびにdream.jsonlへ1行追記するコストのみで、フィードバックループの健全性を後から検証できるようになる。
- 「スキル化提案が放置されている」ことが可視化され、放置ノイズを防ぐ。
- 履歴はマシンローカルのため、PC間で実行履歴は共有されない(auto memory自体が共有されないので許容)。

## 改訂履歴

- 2026-07-08: 初版はgit管理のmarkdownテーブル(`~/.claude/dream-log/DREAM_LOG.md`)としたが、同日中に構造化データ(JSONL)・metrics層(マシンローカル)へ変更。理由: 機械集計のしやすさ、既存metrics規約(`jobs-*.jsonl`)との整合、whitelist方式.gitignoreでdream-log/が同期対象外だった事実との整合。人間可読性はstatusモードの整形出力で担保する。
