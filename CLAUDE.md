## 全体ルール
- 一時ファイル: Subagentや別Agentが読むので.context以下に一時ファイルを作れ。掃除が面倒なので/tmp/とかに作るな（例外: hook/plugin間で受け渡すmarker/state類はcompact-plus等のインフラ規約に従い${TMPDIR}配下。勝手に移動しない）
- compact: 圧縮前state保存と圧縮後復旧はcompact-plus pluginが透過処理する（ADR-0005）。COMPACT PREP REMINDERが注入されたら区切りの良い所でユーザーに/compactを提案しろ。手動state保存は /compact-plus
- ADR: 大きめの変更は常にADR（Architecture Decision Records）を作って保存しろ
- Plan Review: Planを人間に出す前にAIレビューしてIssueを潰してからだせ
- Memory管理: auto memoryはgitリポジトリ単位でworktree間共有される(マシンローカル)。受信箱扱いとし、恒久知見は /memory-dream でgit管理層(CLAUDE.md / rules / repo docs / skills)へ昇格しろ
- 文章表現: 回りくどい表現、誇張表現は基本なし。セッションごとに冗長な言い回しや重複した説明になることをなるべく避けること。日本語は完結した文で書き、矢印記法や体言止めの連鎖で圧縮しない。作業文書は事実の宣言文と短い理由で書き、語りの修辞は読み物に限る（cognitive-rhythm-writing / japanese-tech-writing。一文一行は適用しない）
- 整理整頓: 改善提案やリファクタでは、残骸削除・命名統一・docs現行化・生成物の隔離を機能改善と同列に洗い出し、実施まで提案しろ
- スキル依存: スキルやツールの依存を案内するときはMCPだけでなくCLI（tmux/uv/docker等）も `which` で確認して示せ


## Fableを利用する際のmodel管理について
実装にあたってはトークンを節約するためにOpus/Sonnetを適切にサブエージェントとして切り出して実行し、このメインセッション(Fable 5)は設計と監査、レビューに専念しろ。実装難易度が特に高いところはこのセッションでやってよい