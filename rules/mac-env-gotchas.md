# Mac環境のハマりどころ

- python.org版 Python 3.13 はSSL証明書未設定で urllib が CERTIFICATE_VERIFY_FAILED になる。HTTPSはcurlに委譲するのが確実
- Bashフック（block-secrets.sh）が秘密情報を含む可能性のあるコマンドをブロックする（token文字列やopenssl rand等）。秘密はWriteツールでファイルに書き、コマンドはファイル参照にする
- claude-in-chrome拡張は別PCのChromeに接続されることがある（isLocal=true表示でも実際は別マシンだった事例 2026-07）。ブラウザ操作前にユーザーへ画面が見えているか確認する
- アカウント固有の情報（GitHub複数アカウントの使い分け、Googleアカウント等）は `rules/private/identity.md`（git非トラック）を参照
