# Mac環境のハマりどころ

- python.org版 Python 3.13 はSSL証明書未設定で urllib が CERTIFICATE_VERIFY_FAILED になる。HTTPSはcurlに委譲するのが確実
- Bashフック（block-secrets.sh）が秘密情報を含む可能性のあるコマンドをブロックする（token文字列やopenssl rand等）。秘密はWriteツールでファイルに書き、コマンドはファイル参照にする
- claude-in-chrome拡張は別PCのChromeに接続されることがある（isLocal=true表示でも実際は別マシンだった事例 2026-07）。ブラウザ操作前にユーザーへ画面が見えているか確認する
- アカウント固有の情報（GitHub複数アカウントの使い分け、Googleアカウント等）は `rules/private/identity.md`（git非トラック）を参照
- Docker Desktop の仮想ディスクは他プロジェクトのイメージ・ビルドキャッシュで満杯になり、ビルド中に ENOSPC で落ちる（2026-09-09 実測: キャッシュ 17.9GB/378 件が全て未使用）。長いビルドの前に `docker system df` を見て、Build Cache が大きければ `docker builder prune --filter until=72h -f`（他プロジェクトのイメージ・コンテナは消さない）
- 同一リポでもイメージごとに CPU アーキが違うことがある（例: AgentCore Runtime=arm64 のみ / ECS Fargate アプリ=X86_64）。`docker build --platform` はリポのビルドスクリプトか Dockerfile の `FROM --platform` に固定し、push 後に ECR マニフェストの architecture を検証してからスタック更新する
- Claude Code の Bash ツールはこのMacでは zsh で走る（ログインシェルの fish とは別）。zsh は `log` がビルトインに取られるので、unified log は `/usr/bin/log show ...` とフルパスで書く（素の `log show` は黙って空を返す）。GNU `timeout` は無い。変数に入れた空白区切りの複数値（インスタンス ID 等）は zsh では単語分割されないので、配列にするか直接書く
- macOS 標準 `/bin/bash`（3.2）は UTF-8 locale 下で `$VAR` の直後に全角文字が続くと、先頭バイトまで変数名に含めて `unbound variable` になる（bash 4+ では起きない）。`${VAR}` とブレースで囲む。Bash ツールの環境は C locale で再現しないため、確認は `LC_ALL=ja_JP.UTF-8 /bin/bash script.sh` と locale を明示する。`bash -n` では検出できない。検出: `rg -n --hidden '\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]'`
- `docker login` が keychain の credential helper でハングすることがある。`DOCKER_CONFIG` を一時ディレクトリ（中身 `{"auths":{}}`）に向けて回避する
