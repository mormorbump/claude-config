# ADR-0007: 昇格知見の回帰eval層

- Status: Accepted
- Date: 2026-07-08

## Context

- ADR-0001のメモリアーキテクチャは「収集(auto memory) → 整理・昇格(/memory-dream) → git管理層」の一方向フローで、**昇格したルールがその後も守られているか・前提が現存するかを検証する層がない**。昇格ルールの回帰(ルール消失、参照先の陳腐化、ルール違反状態の再発)は次に人間が気づくまで発見されない。
- 着想は pskoett/pskoett-ai-skills の eval-creator(「失敗から学んだことはeval=回帰テストに固定する。さもなくば知識は脆いまま」)。スキル自体の導入は既存スキル群と重複するため見送り、考え方だけ /memory-dream に取り込む(2026-07-08判断)。

## Decision

### 1. eval = 昇格知見の回帰テスト(markdown 1ファイル)

- /memory-dream のPromoteフェーズで、**機械的にpass/fail判定できる昇格のみ**evalケースを作成する。判定方法を書けない知見はeval化しない。
- 検証方法は4種に限定: `rule-check`(指示ファイルにルールが現存するか) / `file-check`(ファイル・セクション存在) / `grep-check`(パターンの存在・非存在) / `command-check`(コマンドのexitコード・出力)。カスタムスクリプト層は作らない。

### 2. 置き場所(昇格先に随伴)

| 昇格先 | evalの置き場所 | git管理 |
|---|---|---|
| `~/.claude/CLAUDE.md` / `rules/` / `skills/` | `~/.claude/evals/` | ✓ claude-config repo |
| 各repo内 CLAUDE.md / `.claude/rules/` / docs | 各repo内 `.claude/evals/` | ✓ 各repo |

- 構成: `evals/EVAL_INDEX.md`(1行1eval のインデックス) + `evals/cases/eval-YYYYMMDD-NNN.md`。

### 3. 実行タイミング

- **/memory-dream 実行時の冒頭で対象スコープのevalを全実行**する。失敗はMineフェーズの入力(回帰＝再学習対象)として扱い、修正または知見の更新につなげる。
- 専用ランナー・cron・CIは作らない。command-checkベースなので必要なら手動でも回せる。

## やらないこと

- 全昇格のeval化(ノイズ。pass/fail が明確なものだけ)
- evalランナーのスクリプト化・CI統合(現規模では過剰。将来evalが30件を超えて手動実行が苦になったら再検討)
- pskoett-ai-skills 本体の導入(skill-pipeline等のトリガー競合、既存スキルとの重複)

## Consequences

- 昇格ルールの回帰が /memory-dream 実行のたびに機械検出される(外側ループが閉じる)。
- evalの陳腐化リスクは /memory-dream 自身の死参照除去と同じ扱いで剪定する(失敗し続けるevalは知見側の更新か削除を提案)。
