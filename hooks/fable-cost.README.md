# fable-cost — Fable 5 従量課金シミュレータ

現在の Claude Code セッションを「もし Fable 5 が従量課金だったら」の料金で計算し、
macOS 通知で日本円額を出す。実際に動いているモデル(Opus 等)に関わらず Fable 5 レートで換算する。

## 使い方

Stop フックに配線済み。Claude が応答を終えるたびに通知が出る:

```
Fable 利用額
このセッション ¥1,597
$9.90  @ ¥161.4/$
```

手動:

```bash
python3 ~/.claude/hooks/fable-cost.py              # cwd のセッションを自動検出して通知
python3 ~/.claude/hooks/fable-cost.py --no-notify  # 標準出力のみ
python3 ~/.claude/hooks/fable-cost.py --json       # 内訳を JSON 出力
python3 ~/.claude/hooks/fable-cost.py --transcript <path.jsonl>
```

## 料金レート (Fable 5, USD / 100万トークン)

| 種別 | レート | 根拠 |
|---|---|---|
| input | $10 | Fable 5 公式 pricing |
| output | $50 | Fable 5 公式 pricing |
| cache read | $1 | 標準 0.1x |
| cache write 5m | $12.5 | 標準 1.25x |
| cache write 1h | $20 | 標準 2.0x |

為替は `https://open.er-api.com/v6/latest/USD`(キー不要)から curl でライブ取得。
6時間キャッシュ(`.fable-cost-rate.json`)。取得失敗時はキャッシュ→固定値 ¥157 の順にフォールバック。

## ADR: 設計判断

- **なぜ Stop フック + 通知か**: 元ツイートの挙動(応答ごとに通知)に合わせた。settings.json の
  Stop 配列に `async: true` で追加。既存フック(notify/sync-skills/sync-config)と並列実行。
- **message.id で重複排除**: Claude Code は 1 応答を複数の content-block 行に分けて JSONL に書くため、
  同じ `message.id` が複数行に現れる。id ごとに usage を 1 度だけ集計しないと 2〜4 倍に膨れる。
- **為替は curl 委譲**: mac の python.org 版 Python 3.13 は SSL 未設定で urllib が
  CERTIFICATE_VERIFY_FAILED になるため(rules/mac-env-gotchas.md)、HTTPS は curl に委譲。
  毎ターン API を叩かないよう 6h キャッシュ。
- **フックは絶対に失敗させない**: transcript 不明・為替失敗・osascript 失敗いずれも握りつぶして
  exit 0。セッションの流れを止めない。
- **キャッシュ read が支配的**: 長いセッションでは cache_read トークンが大半を占める。これは Fable 5 の
  cache read 単価 $1/1M で正しく計上している(uncached input $10 とは別レート)。

## 無効化

settings.json の Stop 配列から fable-cost.py のエントリを削除すれば止まる。
