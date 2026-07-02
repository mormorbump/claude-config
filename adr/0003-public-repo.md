# ADR-0003: claude-config の public 化とクリーン化

Date: 2026-07-03
Status: Accepted

## Context

repo を public にするにあたり、全 git 履歴を監査した。secret（APIキー・トークン・秘密鍵）は
履歴全体でゼロ、`scripts/.env` も一度も commit されていなかったが、以下の個人情報が見つかった:

1. `rules/mac-env-gotchas.md` が複数 GitHub アカウントと事業用 Google アカウントの
   身元をリンクする情報を含んでいた（履歴にも残存）
2. 全コミットの author が個人メールアドレスだった（public repo ではコミットメタデータから収集可能）
3. `/Users/<username>` の絶対パスが本文・履歴の全域にあり、ハンドル名と実名の紐付けになる

## Decisions

1. **身元関連ルールは `rules/private/`（git 非トラック）へ分離**。公開ルールからは参照のみ。
   非トラックなので PC 間同期されない — 新 PC では手動コピー（README「手動対応」）
2. **パスのユーザー名非依存化**: settings.json のフックコマンドは `$HOME` ベース
   （フックコマンドはシェル経由実行なので環境変数が展開される）。run-job.sh の memory パスは
   `$HOME` からスラグを動的生成。launchd plist は `__HOME__` プレースホルダのテンプレートとし、
   install-launchd.sh がインストール時に置換（launchd は plist 内の環境変数を展開しないため）
3. **コミットメールは GitHub noreply に変更**（repo ローカルの git config）
4. **履歴は orphan コミットで作り直し、force push**。旧履歴は個人情報を含むため公開しない。
   ローカルにはブランチ `pre-public-backup` として保全（push しない）
5. **他 PC の追従は sync-config.sh が自動化**: fetch 後に `git merge-base` で共通祖先の消失を
   検出したら、ローカルを `backup-before-reset-<ts>` ブランチに退避して `reset --hard origin/main`。
   未トラックのローカルデータ（metrics / memory / logs / rules/private / settings.local.json）は
   whitelist gitignore の対象外なので影響を受けない。
   ただし**今回の1回だけ**は他 PC も旧 sync-config.sh で動いているため、rebase 失敗通知の後に
   各 PC で手動 `git fetch origin && git reset --hard origin/main` が必要

## 残留リスク

- force push 後も GitHub 側に旧履歴の dangling オブジェクトが一時的に残り、SHA を知っていれば
  取得できる。旧 SHA は private 時代のもので外部に出ていないため実質リスクは無視できるが、
  完全を期すなら web UI で repo を削除→同名再作成→push し直す選択肢がある
- コミットメールの変更は新履歴にのみ適用（旧履歴は公開しないので問題にならない）
