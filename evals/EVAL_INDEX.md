# Eval Index（グローバル昇格知見の回帰eval / ADR-0007）

/memory-dream 実行時に全実行し、このテーブルを更新する。ケースは `cases/eval-YYYYMMDD-NNN.md`。

| ID | Rule | Last Run | Result |
|---|---|---|---|
| eval-20260716-001 | kawatani-email: 受諾確定で埋め草の次アクション予告を創作しない | 2026-09-30 | △ 88%（非critical 1件違反） |
| eval-20260716-002 | kawatani-email: 指示にない確定値（金額等）を創作せずプレースホルダー+依頼者確認 | 2026-09-30 | × critical fail |
| eval-20260716-003 | kawatani-email: 初回断りでFIGJAM形名乗り（テンプレ#3分岐） | 2026-09-30 | ○ 100% |
| eval-20260716-004 | kawatani-email: 初回条件確認で技術詳細を先方質問に混入しない（hold-out） | 2026-09-30 | ○ 100% |
