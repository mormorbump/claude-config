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
- **同期範囲は `.gitignore` のwhitelist方式で定義**(ADR-0001)。track対象に明示されたもの(CLAUDE.md / rules / adr / hooks / scripts / evals / settings.json等)だけが同期され、それ以外(metrics / memory / logs / settings.local.json / rules/private)は黙って除外される。**新しいディレクトリを同期させたい場合はwhitelistへの追加が必要**(追加漏れはエラーにならず、単に同期されない)
- **反映タイミングはStop hook駆動**(デーモンではない)。別PCへの反映は、そのPCでClaude Codeのセッションが1ターン終了したときにfetch+rebaseで取り込まれる
- **履歴リライト(force push)への追従**: sync-config.shが共通祖先の消失を検出すると、ローカルを`backup-before-reset-*`ブランチに退避して`origin/main`へ自動`reset --hard`する。未トラックのローカルデータ(metrics/memory/logs)は影響を受けない

## アーキテクチャ

3層構造: **git層**(全PCへ同期される決定的な仕組み) / **ローカル層**(同期しない揮発データ) /
**昇格フロー**(知見だけが人間・ジョブの判断でgit層に上がり、結果的に同期される)。
セキュリティ層はfail-closed、計測層はfail-openと、層ごとに逆へ倒す(詳細はADR-0002)。

以下、「ランタイム構造(hookと層の配置)」と「知見ライフサイクル(何がどう昇格するか)」の2枚に分けて示す。

### ランタイム構造

```mermaid
graph TB
    subgraph runtime["Claude Code セッション（対話 / headless 共通）"]
        agent["エージェント（LLM・非決定的）"]
        pre["PreToolUse: block-secrets.sh<br/>fail-closed / Bash・Read・Grep<br/>秘密ファイル読取→ask, 危険操作→deny"]
        post["PostToolUse: metrics.sh<br/>fail-open / 全ツール, async"]
        stop["Stop: sync-skills.sh / sync-config.sh<br/>secretスキャン→commit→fetch+rebase→push<br/>（他PCからの受信も同じタイミング）"]
        agent -->|ツール実行要求| pre
        pre -->|allow / ask / deny| agent
        agent -->|実行後イベント| post
    end

    subgraph gitlayer["git層（全PCへ同期。範囲は.gitignoreのwhitelistで定義）"]
        config["claude-config（このrepo）<br/>CLAUDE.md / rules / adr / hooks /<br/>scripts / settings.json / evals"]
        skills["claude-skills（別repo）"]
        vault["Obsidian vault（別系統: obsidian-gitが毎分push）<br/>Zettelkasten/PermanentNote"]
    end

    subgraph local["ローカル層（マシンローカル・同期しない）"]
        metrics["metrics/*.jsonl<br/>usage-*(ツール実績) / jobs-*(ジョブ実績) /<br/>dream.jsonl(/memory-dream実績)"]
        memory["auto memory 受信箱<br/>~/.claude/projects/&lt;スラグ&gt;/memory/"]
        locals["settings.local.json / logs / rules/private"]
    end

    subgraph autonomous["自律実行（launchd, PCごとに登録）"]
        launchd["launchd 平日9:00（best-effort）"]
        runner["run-job.sh（汎用ジョブランナー）<br/>lock / timeout / retry / metrics記録 /<br/>後段secretスキャン→quarantine"]
        launchd --> runner
        runner -->|"claude -p + prompts/knowledge-extract.md<br/>（Sonnet・権限制限つき）"| agent
    end

    post --> metrics
    stop <-->|双方向sync| config
    stop <-->|双方向sync| skills
    memory -->|"昇格（下図参照）"| gitlayer
```

- **git層**: 正本。全PCで同一になるべき決定的な設定・知見・手順。同期対象は `.gitignore` のwhitelistが唯一の定義(漏れるとエラーなく非同期になる点に注意)
- **ローカル層**: そのマシンでしか意味を持たないデータ。auto memoryは「まだ昇格していない知見の受信箱」、metricsは自己観測ログ。PC間で共有されないのは仕様
- **自律実行**: run-job.sh自体はロック・タイムアウト・リトライ・通知だけの汎用ランナーで、ジョブの中身は `scripts/jobs/prompts/*.md` のプロンプトが定義する(現行ジョブはknowledge-extractのみ)

### 知見ライフサイクル（収集→昇格→回帰検証）

自動の**収集ループ**(knowledge-extract、日次)と、人間トリガーの**整理・昇格ループ**(/memory-dream)の2段構え。
昇格した知見はeval(回帰テスト)で固定し、次回の/memory-dream冒頭で守られているか機械検証する(ADR-0007〜0009)。

```mermaid
graph TB
    session["各セッション"] -->|auto memory 自動追記<br/>（repo単位の受信箱）| inbox
    session -->|生ログ| tlog["transcript<br/>~/.claude/projects/*/*.jsonl"]
    tlog -->|"knowledge-extract（平日9:00）<br/>直近26h・末尾200KB・PIIガード最優先<br/>※書込先はHOMEスラグ受信箱に固定"| inbox["memory 受信箱（マシンローカル）<br/>確度低いものは (proposal) 付き"]
    tlog -.->|"一般化可能な原理のみ直接昇格<br/>（高いバー。0件が正常）"| vault

    inbox -->|"/memory-dream（人間トリガー・HITL）"| dream["0. 既存eval全実行（回帰検出）<br/>1. Mine（採掘。eval失敗も入力）<br/>2. Consolidate（重複マージ・死参照除去）<br/>3. Promote（昇格）<br/>4. Prune &amp; Index（剪定）"]

    dream -->|常時従う行動指示 / 条件付き規約| cfg["claude-config:<br/>CLAUDE.md / rules"]
    dream -->|繰り返し手順<br/>（skill化は提案のみ）| sk["claude-skills"]
    dream -->|プロジェクト固有| repo["各repo:<br/>CLAUDE.md / docs / adr"]
    dream -.->|"一般化可能な個人知識<br/>（knowledge-extractの拾い漏れの補完・低頻度<br/>基準はknowledge-extract.mdと同一, ADR-0009）"| vault["Obsidian PermanentNote"]

    dream -->|"pass/fail明確な昇格のみeval化<br/>（ADR-0007）"| evals["evals/ EVAL_INDEX + cases<br/>（git同期）"]
    evals -->|次回実行の冒頭で全実行<br/>失敗＝回帰としてMineへ| dream
    dream -->|実行実績を1行追記<br/>（ADR-0008）| dlog["metrics/dream.jsonl<br/>（マシンローカル）"]
    dlog -->|"/memory-dream status<br/>（読み取り専用・整形レポート）"| human["人間"]
```

- **実線=自動または通常フロー、点線=高いバー付きの例外的フロー**
- **knowledge-extractと/memory-dreamの役割分担**: 前者は候補の自動掘り起こし(無人・保守的・日次)、後者は人間判断による正本への昇格(HITL・CLAUDE.md変更はdiff提案止まり)。Obsidian昇格の判定基準は `scripts/jobs/prompts/knowledge-extract.md` が単一情報源で、/memory-dream側はそれを参照する
- **非対称に注意**: auto memoryの受信箱はrepo単位だが、knowledge-extractジョブは全repoのtranscriptを読んで**HOMEスラグの受信箱1箇所**に書く。repoスコープだけで/memory-dreamを回すとジョブ由来の知見を拾い漏れるため、定期的にHOMEスコープ(または「全部」)で実行する
- **計測**: mined/promoted等の件数はモデルの自己申告(hookでは決定的に取れない)、eval合否のみ実コマンドの客観結果。履歴はマシンローカルなのでPC横断の累計は見られない

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
