# ADR-0006: config sync のトラック対象からマシンローカル状態ファイルを除外

Date: 2026-07-07
Status: Accepted

## 背景

`~/.claude`（claude-config repo）は `hooks/sync-config.sh`（Stop hook）で origin/main と双方向同期している。流れは「ローカル変更を commit → fetch + rebase でリモート取込 → 先行分を push」で、rebase 競合時は `rebase --abort` して push せず終了する（ADR-0001 の whitelist 方式でトラック対象を制御）。

複数マシンで運用中、sync が ahead/behind の膠着状態（例: ahead 2 / behind 3）に陥り、意味のあるリモート変更がローカルに取り込まれず、ローカルの commit も push されない状態が続いた。

### 根本原因

`hooks/.fable-cost-rate.json`（Fable のコスト計算用に為替レートを取得して毎回上書きする状態ファイル）が `.gitignore` の whitelist `!/hooks/**` によって**トラック対象に入っていた**。

中身は `{"rate": ..., "ts": ...}` のみで、各マシンの hook 実行のたびに別値で書き換わる。結果:

1. マシンAで hook 実行 → ファイル更新 → auto-sync が commit（ローカル先行が増える）
2. push 前の rebase で、リモート（マシンB由来）も同じファイルを別値で更新済み → **必ず content conflict**
3. sync-config.sh は競合時 `rebase --abort` → push せず終了
4. push できないローカル commit が溜まり続け、双方向 sync が恒久的に膠着

commit 内容は「レート値の1行上書き」だけで、履歴に残す価値がない。

## 決定

マシンごとに毎回書き換わる状態ファイルは config sync のトラック対象から除外する。

### 実施

- `.gitignore` に `/hooks/.fable-cost-rate.json` を追加（whitelist `!/hooks/**` の後で個別に再 ignore）
- `git rm --cached hooks/.fable-cost-rate.json`（ディスク上のファイルは残す＝hook は従来通り動く）
- 膠着解消として、レート上書きだけのローカル先行 commit を `git reset --hard origin/main` で破棄しリモートへ追従

## 原則

**hooks/** を whitelist で丸ごとトラックする構成上、「マシンごとに変わる生成物 / 状態ファイル / キャッシュ」を hooks 配下に置くと同じ膠着を再発させる。この種のファイルは:

- トラックしない（`.gitignore` で個別 ignore）
- ドット始まりの状態ファイルは `.fable-*` のようにパターンで一括除外することも検討（現状は該当1件のため個別指定に留めた）

sync が ahead/behind で膠着したら、まず `git log origin/main..HEAD` と `git log HEAD..origin/main` の diff stat を見て「毎回書き換わる状態ファイルだけの commit」が犯人でないか疑う。

## 関連

- ADR-0001（memory architecture / whitelist 方式の .gitignore）
- `hooks/sync-config.sh`（双方向 sync の実装。競合時 abort する設計は維持。競合の火種を持ち込まない側で対処する方針）
