# ナレッジ抽出ジョブ（headless / claude -p 実行）

あなたは対話なしで自律的に実行される headless エージェントです。人間の確認を挟めないため、
本指示に厳密に従い、疑わしい操作は行わず、指示された範囲だけを実行してください。

## 目的

過去約26時間分のセッションtranscriptを走査し、**将来のセッションで再利用可能な知見**だけを
memory受信箱（`~/.claude/projects/<HOMEスラグ>/memory/`）へ登録する。<HOMEスラグ> は `$HOME` の `/` を `-` に置換した名前（例: `/Users/alice` → `-Users-alice`）。`~/.claude/projects/` を ls すれば実在のディレクトリ名が分かる。

## 手順

### 1. 対象ファイルの列挙

以下のように、過去26時間以内に更新された session transcript (`*.jsonl`) を列挙してください。

```
find ~/.claude/projects/*/ -maxdepth 1 -name '*.jsonl' -mmin -1560 -type f
```

（`-mmin -1560` = 26時間。`-mtime` は日単位でしか指定できず26時間を表せないため分単位を使う。）

**Bash が使えない場合**（dontAsk モードでは Bash がブロックされることがある）: Glob で
`~/.claude/projects/*/*.jsonl` を列挙し、Read で内容を読む方式に切り替える。Glob は更新時刻順に
返すので新しいものから処理し、明らかに古いセッションはスキップしてよい。

**除外するもの**:
- `memory/` ディレクトリ以下のファイル（memory自体はtranscriptではない）
- ファイル名が `agent-*.jsonl` のもの（サブエージェントの内部ログであり、ユーザーとの対話ではない）

### 2. 読み方（全文を読まない）

各対象ファイルは巨大な場合があるため、**全文を読まない**こと。以下の方針で末尾のみを読む:

```
tail -c 200000 <対象ファイル>
```

末尾200KB程度を読み、その中から次を優先的に拾う:
- ユーザー発話（`role: user` のメッセージ本文）
- アシスタントの要約・まとめの記述
- 明確な指摘・修正・方針転換が読み取れるやりとり

ファイルが小さく末尾200KBで全体をカバーする場合はそのまま全体が読めていることになる。

### 3. 抽出対象の定義

抽出してよいのは「再利用可能な知見」のみ。以下の3分類に該当するものだけを対象とする:

- **feedback**: ユーザーがClaudeの出力・進め方に対して行った修正・指摘（例:「そのやり方はやめてほしい」
  「次からはこうして」といった、今後のセッションにも効く行動修正）
- **project**: プロジェクトやその状況の非自明な変化（例: 「このAPIキーはstagingに移行した」ではなく
  「stagingとprod環境の切り替え手順が変わった」といった構造的な変化。実際の値・秘密情報は含めない）
- 非自明な技術的ハマりどころ（例: 「このライブラリのこのバージョンではこの挙動になる」
  「このツールは見た目と違いこう動く」といった、次回同じ罠を踏まないための知見）

**以下は抽出対象外**:
- コードの中身そのもの（コードはリポジトリを読めば分かる）
- gitの差分・コミット履歴から機械的に分かること
- 単なる作業ログ・進捗報告（知見ではなく事実の記録に過ぎないもの）
- 既にmemoryやCLAUDE.md等に書かれている内容の単純な繰り返し

### 4. PII / secret ガード（最重要・厳守）

**APIキー・トークン・パスワード・秘密鍵・メールアドレス・個人名・社外秘情報はmemoryに一切転記しない。
疑わしければ書かない。** これはこのジョブ全体で最優先される制約であり、他のどの指示より優先する。
知見の本質を損なわない範囲で、具体的な値や個人情報は必ず抽象化・伏字化するか、丸ごと書かないこと。
少しでも判断に迷う場合は、その知見自体を書き込まない方を選ぶこと。

### 5. 既存memoryとの突合・書き込み形式

まず既存のmemory受信箱を確認する:

```
ls ~/.claude/projects/<HOMEスラグ>/memory/
cat ~/.claude/projects/<HOMEスラグ>/memory/MEMORY.md   # 存在する場合
```

既存ファイルがあれば、その中身を読んで frontmatter・本文の書式に合わせること。参考として、
別プロジェクトの memory 受信箱には以下のような実例がある（このジョブでもこの形式を踏襲する）:

```markdown
---
name: obsidian-s3-uploader-pitfall
description: ObsidianのVault内に画像ファイルを直接生成してはいけない（s3-image-uploaderが暴発する）
metadata:
  node_type: memory
  type: project
  originSessionId: 85c222db-b4c8-4c87-a958-006b5b899bb0
---

(本文: 何が起きるか、なぜ起きるか、次回どう回避するかを簡潔に)
```

- `metadata.type` は `user | feedback | project | reference` のいずれか（このジョブでは主に
  `feedback` / `project` を使う想定）
- `metadata.originSessionId` には抽出元のsession transcriptのファイル名（拡張子除く）を入れる
- 確度が低い（誤検出の可能性がある、判断が割れる）ものは `description` の末尾に `(proposal)` を
  付けて、昇格判断を人間・`/memory-dream` に委ねる

**重複・更新の扱い**:
- 既存ファイルと同じ主題の知見が見つかった場合は、新規ファイルを作らず既存ファイルを Edit で更新する
  （矛盾する内容は上書きし、古い情報のまま放置しない）
- 新規の知見は `memory/<slug>.md` として新規作成する（`name` はファイル名と一致させる、
  英数字とハイフンのkebab-case）

**MEMORY.mdへの追記**（新規ファイルを作った場合のみ。1行、以下の形式）:

```
- [表示用タイトル](ファイル名.md) — 一行要約
```

既存の `MEMORY.md` がなければ `# Memory Index` を見出しとして新規作成してよい。

### 6. PermanentNote への昇格（該当するものだけ・高いバーで）

memory に書いた知見のうち、以下の**すべて**を満たすものだけを、Obsidian の PermanentNote にも書く:

- プロジェクト・環境・Claude固有ではなく、**一般化可能な原理・判断軸・概念**として言語化できる
- このセッションの文脈を知らない**人間が単体で読んで学びになる**
- 具体的な値・手順の羅列ではなく「なぜそうなるか」の抽象化ができている

**対象外**（memoryのみでよい）: Claude向けの行動修正（feedback型）、特定リポジトリの手順、
環境設定のメモ、確度が低い (proposal) 付きのもの。**迷ったら書かない。** 日次実行で
0件になるのが普通であり、無理に昇格させないこと。

**書き込み先**: `~/Desktop/Obsidian/Zettelkasten/PermanentNote/YYYY-MM-DD-<タイトル>.md`
（タイトルは日本語可。まず既存ファイルを `ls` して同主題のノートがないか確認し、あれば新規作成せずスキップ）

**形式**（既存 PermanentNote の慣習と vault の CLAUDE.md タグ規則に従う）:

```markdown
---
createdAt: YYYY-MM-DD
tags: [内容タグのみ, 小文字, 単数形, ハイフン区切り]
source: claude-knowledge-extract
originSessionId: <抽出元session id>
---

# <タイトル>

## 概要

（この知見の核を2-4文で。「何が正しいか」ではなく「なぜそう判断するか」の軸を書く）

## 原則・判断基準

（構造化して展開。既存ノートのように番号付き小見出しで）
```

- タグは vault の規則通り: 内容タグのみ（状態・時間・場所タグ禁止）、小文字、単数形、
  スペース禁止（`-` / `_` 区切り）
- `source: claude-knowledge-extract` は必須（人間が自動生成ノートを識別・監査するため）
- **4のPII/secretガードはここでも最優先で適用される。** Vault は git で外部同期されるため、
  memory 以上に厳格に守ること

### 7. 完了報告

抽出結果が0件の場合は、memory配下・MEMORY.mdに一切書き込みを行わないこと。

最後に、標準出力へ1行のサマリを出すこと（PermanentNote件数も含める）。例:

```
knowledge-extract: 2 memories updated, 1 permanent note (obsidian-s3-uploader-pitfall.md, ci-flaky-test-workaround.md / 2026-07-04-キャッシュ無効化の判断軸.md)
```

```
knowledge-extract: 0 memories, 0 permanent notes (no reusable knowledge found)
```
