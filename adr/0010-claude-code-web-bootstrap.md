# ADR-0010: Claude Code on the web 用ブートストラップとグローバル/ローカル切り分け

Date: 2026-07-21
Status: Accepted

## 背景

Claude Code on the web（claude.ai/code）の Routine で開発タスクを定期実行する運用を開始する（参考: https://zenn.dev/mizchi/scraps/4e5d72496e2bfc ）。

クラウドコンテナから見えるのは「対象repoにコミットされた内容」と「claude.ai側で有効化したスキル」だけで、手元の `~/.claude`（グローバルCLAUDE.md / rules / skills / settings.jsonのhooks）は一切届かない。

公式docsで確認した事実（2026-07-21、code.claude.com/docs/en/claude-code-on-the-web.md, hooks.md, routines.md）:

- SessionStart hook はrepoコミットの `.claude/settings.json` 登録分のみクラウドで実行される。ローカル `~/.claude/settings.json` のhookはクラウドでは実行されない
- hookはローカル・クラウド両方で走る。クラウド判定は `CLAUDE_CODE_REMOTE=true`
- スキルはrepoの `.claude/skills/` に置けば読まれる。ユーザーレベル `~/.claude/skills` はクラウドでは読まれない
- クラウドセッションのgitは「接続GitHubアカウントが見える全repo」にアクセス可能（private の claude-skills もclone可）。pushはGitHub proxyにより作業ブランチのみに制限
- Setup script（環境設定UI、結果が約7日キャッシュ）と SessionStart hook（毎回実行）は別物。依存インストールが重くなったらSetup script側へ移す
- claude-config は「repoルート = ~/.claude の中身」という構造のため、クラウドがproject設定として読むのはネストした `/.claude/settings.json` になる

## 決定

1. **切り分け基準**: Routine/クラウドセッションに効かせたい設定・ルール・スキルは対象repoのgit管理層へコミットする。全プロジェクト共通スキルは claude.ai 側の有効化で配る。手元の `~/.claude` だけにあるものはクラウドでは存在しないものとして扱う。/memory-dream の昇格判断に「クラウドで効かせる必要があるか」の観点を加える
2. claude-config repoにネストした `/.claude/`（settings.json + hooks/session-start.sh）を追加し、このrepoがクラウドで開かれた時のブートストラップとする
3. session-start.sh は `CLAUDE_CODE_REMOTE` ガードで非クラウド時は即終了（ローカル無害・低レイテンシ）。クラウドでは claude-skills(private) を `<repo>/.claude/skills` に shallow clone する
4. Routineは個人アカウント紐付けでチーム共有機能がない点に留意（org repoでは登録の重複に注意）。まず claude-config 対象の低リスクRoutine（毎朝のPR rebase + ブートストラップ検証）でhook動作・スキル認識・トークン消費の肌感を検証してから他repoへ展開する

## 実施

- `/.claude/settings.json`: hooks.SessionStart に session-start.sh を登録（timeout 300s）
- `/.claude/hooks/session-start.sh`: クラウド判定 → claude-skills clone → `reloadSkills` + `additionalContext` をJSON出力
- `.gitignore`: whitelist に `!/.claude/` `!/.claude/**` を追加。クラウド側clone物の `/.claude/skills/` は個別ignore（ADR-0006「生成物をtrackしない」原則）
- Routine「毎朝PR rebase」は claude.ai/code/routines（Web UI）で登録する。注意: デスクトップ/CLIの scheduled-tasks MCP（~/.claude/scheduled-tasks/）は「アプリが開いている間だけローカル実行」される別機能であり、クラウドRoutineではない

## 未確認事項

- SessionStart hook出力の `reloadSkills` フィールドの正確な挙動（docsに記載はあるが詳細未確認。未対応でも無視されるだけで実害なし）
- private repo の clone が GitHub 認証方式（App install / OAuth）どちらでも通るか → 初回Routine実行ログで実地確認する
- 他repo（revia等）へ展開する場合は、同等の settings.json + session-start.sh をそのrepoの `.claude/` にコミットする（このrepoのネスト構造は claude-config 固有の事情）

## 関連

- ADR-0001（whitelist方式 .gitignore）
- ADR-0006（マシンローカル生成物をtrackしない原則）
- ADR-0003（public repo運用。claude-skills は private のまま、クラウドからはgit認証でclone）
