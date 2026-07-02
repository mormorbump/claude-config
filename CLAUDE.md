## 全体ルール
- 一時ファイル: Subagentや別Agentが読むので.context以下に一時ファイルを作れ。掃除が面倒なので/tmp/とかに作るな
- ADR: 大きめの変更は常にADR（Architecture Decision Records）を作って保存しろ
- Plan Review: Planを人間に出す前にAIレビューしてIssueを潰してからだせ
- Memory管理: auto memoryはgitリポジトリ単位でworktree間共有される(マシンローカル)。受信箱扱いとし、恒久知見は /memory-dream でgit管理層(CLAUDE.md / rules / repo docs / skills)へ昇格しろ
- 文章表現: 回りくどい表現、誇張表現は基本なし。セッションごとに冗長な言い回しや重複した説明になることをなるべく避けること


## model管理について
実装にあたってはトークンを節約するためにOpus/Sonnetを適切にサブエージェントとして切り出して実行し、このメインセッション(Fable 5)は設計と監査、レビューに専念しろ。実装難易度が特に高いところはこのセッションでやってよい