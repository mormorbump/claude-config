# claude-config

Claude Codeのグローバル設定(CLAUDE.md / rules / adr / hooks / scripts / settings)のgit管理。設計はADR-0001参照。skillsは別repo( https://github.com/mormorbump/claude-skills )。

## 別PCへのセットアップ

前提: git / gh / GitHubのSSHキー(mormorbumpアカウント)が使えること。

```bash
# 1) Claude Codeを一度起動して ~/.claude を生成しておく

# 2) 既存ファイルを退避(上書きされるのはtrack対象のみ)
cd ~/.claude
mkdir -p ../claude-backup && cp -a CLAUDE.md settings.json ../claude-backup/ 2>/dev/null

# 3) claude-config を既存の ~/.claude に重ねる
git init
git remote add origin git@github.com:mormorbump/claude-config.git
git fetch origin
git checkout -f -b main origin/main

# 4) skills を clone
git clone git@github.com:mormorbump/claude-skills.git ~/.claude/skills
```

## 手動対応が必要なもの(repoに含まれない)

- `rules/private/`: アカウント・身元関連のルール(git非トラック)。必要なら手動コピー
- `scripts/.env`: Discord Botトークン。必要なら安全な手段で個別コピー
- `~/.claude.json`: MCPサーバ設定はこのrepoの対象外(ADR-0001の既知の限界)。新PCで再設定
- `settings.local.json`: マシンローカルのpermission設定。必要なら再作成
- launchd(`com.mormorbump.claude-skills-sync`): skills定期syncを新PCでも回すなら `~/Library/LaunchAgents` にplistを別途作成
- launchd(`com.claude.job-knowledge-extract`): 日次ナレッジ抽出ジョブ(ADR-0002)。新PCでは `bash ~/.claude/scripts/jobs/install-launchd.sh` を1回実行(冪等)

## 日常の同期

- **skills**: Stop hook(`hooks/sync-skills.sh`)が自動で双方向sync(commit→rebase→push)
- **config(このrepo)**: Stop hook(`hooks/sync-config.sh`)が自動で双方向sync。commit前に追加行のsecretスキャンを行い、検出時はcommitを中止して通知する。rebase競合時も通知(手動解決)
- **履歴リライト(force push)への追従**: sync-config.shが共通祖先の消失を検出すると、ローカルを`backup-before-reset-*`ブランチに退避して`origin/main`へ自動`reset --hard`する。未トラックのローカルデータ(metrics/memory/logs)は影響を受けない

## アーキテクチャ

3層構造: **git層**(全PCへ同期される決定的な仕組み) / **ローカル層**(同期しない揮発データ) /
**昇格フロー**(知見だけが人間・ジョブの判断でgit層に上がり、結果的に同期される)。
セキュリティ層はfail-closed、計測層はfail-openと、層ごとに逆へ倒す(詳細はADR-0002)。

```mermaid
graph TB
    subgraph runtime["Claude Code セッション（対話 / headless 共通）"]
        agent["エージェント（LLM・非決定的）"]
        pre["PreToolUse: block-secrets.sh<br/>fail-closed / Bash・Read・Grep<br/>秘密ファイル読取→ask, 危険操作→deny"]
        post["PostToolUse: metrics.sh<br/>fail-open / 全ツール, async"]
        stop["Stop: sync-skills.sh / sync-config.sh<br/>（secretスキャン→commit→rebase→push）"]
        agent -->|ツール実行要求| pre
        pre -->|allow / ask / deny| agent
        agent -->|実行後イベント| post
    end

    subgraph gitlayer["git層（全PCへ同期）"]
        config["claude-config（このrepo）<br/>CLAUDE.md / rules / adr /<br/>hooks / scripts / settings.json"]
        skills["claude-skills"]
        vault["obsidian vault<br/>（PermanentNote, obsidian-git毎分push）"]
    end

    subgraph local["ローカル層（同期しない）"]
        metrics["metrics/*.jsonl<br/>（ツール/スキル/ジョブ利用実績）"]
        memory["memory 受信箱"]
        locals["settings.local.json / logs"]
    end

    subgraph autonomous["自律実行（launchd, PCごとに登録）"]
        launchd["launchd 平日9:00（best-effort）"]
        runner["run-job.sh<br/>lock / timeout / retry / secretスキャン"]
        launchd --> runner
        runner -->|"claude -p（権限制限つき）"| agent
    end

    post --> metrics
    stop --> config
    stop --> skills
    runner -->|knowledge-extract| memory
    runner -->|一般化可能な知見のみ<br/>（高いバー）| vault
    memory -->|"/memory-dream で昇格<br/>（人間トリガー）"| config
    memory -.->|恒久知見| skills
```

### シーケンス: ツール実行1回のフック処理

```mermaid
sequenceDiagram
    participant A as エージェント
    participant CC as Claude Code
    participant Pre as block-secrets.sh
    participant U as 人間
    participant Post as metrics.sh

    A->>CC: ツール呼び出し（Bash/Read/Grep）
    CC->>Pre: stdin: {tool_name, tool_input, cwd}
    alt 危険パターンなし
        Pre-->>CC: 出力なし, exit 0（許可）
    else 秘密ファイル読み取り（実在+symlink解決で確定）
        Pre-->>CC: {permissionDecision: ask}
        CC->>U: 確認（HITL。ローカルはMercariと違いdenyでなくask）
    else 危険操作（秘密値送信・rm -rf等）
        Pre-->>CC: {permissionDecision: deny}
    else フック自体のクラッシュ・jq不在・不正入力
        Pre-->>CC: stderr+exit 2（fail-closed: 黙って許可しない）
    end
    CC->>A: ツール実行
    CC--)Post: 実行後イベント（async）
    Post--)Post: usage-YYYY-MM.jsonl へ1行追記<br/>（どんなエラーでも exit 0 = fail-open）
```

### シーケンス: 自律ジョブ（knowledge-extract）

```mermaid
sequenceDiagram
    participant L as launchd（平日9:00）
    participant R as run-job.sh
    participant C as claude -p（Sonnet）
    participant M as memory 受信箱
    participant V as Obsidian PermanentNote

    L->>R: run-job.sh knowledge-extract
    R->>R: jobs.json 読込 / mkdirロック（二重起動forbid）
    loop 最大 backoff_limit+1 回
        R->>C: プロセスグループ起動 + watchdog（timeout）
        C->>C: 直近26hのtranscriptから知見抽出<br/>（PII/secretガード最優先）
        C->>M: memory形式で書込・MEMORY.md更新
        C-->>V: 一般化可能な原理・判断軸のみ<br/>（迷ったら書かない。0件が正常）
        C-->>R: rc
    end
    R->>M: secretスキャン→ヒットは .quarantine
    R->>V: secretスキャン→ヒットはvault外へ隔離+履歴確認通知<br/>（obsidian-gitのpushに間に合わない可能性あり）
    R->>R: metrics記録 / 最終失敗時のみ通知
    Note over M: 昇格は /memory-dream（人間トリガー）
```
