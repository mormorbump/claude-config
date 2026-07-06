#!/usr/bin/env python3
"""Fable 5 従量課金シミュレータ / 現セッションのコストを日本円で通知する。

実際のモデルに関わらず「もし Fable 5 が従量課金だったら」の料金を計算する。
Claude Code の Stop フックから stdin 経由で transcript_path を受け取り、
macOS 通知(osascript)で「Fable このセッション ¥XXX」を表示する。

手動実行:
    python3 fable-cost.py                # cwd から現在のセッションを自動検出
    python3 fable-cost.py --transcript /path/to/session.jsonl
    python3 fable-cost.py --json         # 内訳を JSON で出力(通知しない)
    python3 fable-cost.py --no-notify    # 標準出力のみ

設計判断は fable-cost.README.md を参照。
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

# --- Fable 5 従量課金レート (USD / 100万トークン) ---
# https://platform.claude.com/docs/en/pricing (Fable 5: $10 in / $50 out)
# キャッシュは Anthropic の標準倍率: read=0.1x, write5m=1.25x, write1h=2.0x
RATE_INPUT = 10.0
RATE_OUTPUT = 50.0
RATE_CACHE_READ = 1.0
RATE_CACHE_WRITE_5M = 12.5
RATE_CACHE_WRITE_1H = 20.0

# 為替: ライブ取得失敗時のフォールバック
FALLBACK_USDJPY = 157.0
RATE_CACHE_TTL_SEC = 6 * 3600  # 為替キャッシュの有効期限
RATE_CACHE_FILE = Path(__file__).with_name(".fable-cost-rate.json")
FX_URL = "https://open.er-api.com/v6/latest/USD"

PROJECTS_DIR = Path.home() / ".claude" / "projects"


def _usd_jpy() -> tuple[float, str]:
    """USD→JPY レートを返す。(rate, source)。

    キャッシュが新しければそれを使い、古ければ curl でライブ取得(mac の
    Python urllib は SSL 未設定で落ちるため curl に委譲)。失敗時は
    キャッシュ→固定値の順にフォールバックし、通知は絶対に止めない。
    """
    now = time.time()
    cached = None
    try:
        cached = json.loads(RATE_CACHE_FILE.read_text())
        if now - cached.get("ts", 0) < RATE_CACHE_TTL_SEC:
            return float(cached["rate"]), "cache"
    except Exception:
        pass

    try:
        out = subprocess.run(
            ["curl", "-fsS", "--max-time", "3", FX_URL],
            capture_output=True, text=True, timeout=5,
        )
        data = json.loads(out.stdout)
        rate = float(data["rates"]["JPY"])
        if rate > 0:
            try:
                RATE_CACHE_FILE.write_text(json.dumps({"rate": rate, "ts": now}))
            except Exception:
                pass
            return rate, "live"
    except Exception:
        pass

    if cached and cached.get("rate"):
        return float(cached["rate"]), "cache(stale)"
    return FALLBACK_USDJPY, "fallback"


def _resolve_transcript(explicit: str | None) -> Path | None:
    """transcript の jsonl パスを決定する。

    明示指定 > cwd に対応する projects ディレクトリの最新 jsonl。
    """
    if explicit:
        p = Path(explicit)
        return p if p.exists() else None

    cwd = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    # Claude Code のプロジェクトディレクトリ名は cwd の / と . を - に置換したもの
    slug = cwd.replace("/", "-").replace(".", "-")
    proj = PROJECTS_DIR / slug
    if not proj.is_dir():
        return None
    jsonls = sorted(proj.glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    return jsonls[0] if jsonls else None


def compute_tokens(transcript: Path) -> dict:
    """transcript を走査し、message.id で重複排除してトークンを合計する。

    Claude Code は 1 応答を複数の content-block 行に分けて書くため、
    同じ message.id が複数行に現れる。id ごとに usage を 1 度だけ数える。
    """
    seen: dict[str, dict] = {}
    model = None
    with transcript.open() as fh:
        for line in fh:
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if obj.get("type") != "assistant":
                continue
            msg = obj.get("message") or {}
            usage = msg.get("usage")
            mid = msg.get("id")
            if not usage or not mid:
                continue
            model = msg.get("model") or model
            seen[mid] = usage  # 同一 id は最終 usage で上書き(値は同じ)

    tot = {"input": 0, "output": 0, "cache_read": 0, "cache_w5m": 0, "cache_w1h": 0}
    for u in seen.values():
        tot["input"] += u.get("input_tokens", 0) or 0
        tot["output"] += u.get("output_tokens", 0) or 0
        tot["cache_read"] += u.get("cache_read_input_tokens", 0) or 0
        cc = u.get("cache_creation") or {}
        w5 = cc.get("ephemeral_5m_input_tokens")
        w1 = cc.get("ephemeral_1h_input_tokens")
        if w5 is None and w1 is None:
            # 内訳が無い古い形式は 5m 扱い
            tot["cache_w5m"] += u.get("cache_creation_input_tokens", 0) or 0
        else:
            tot["cache_w5m"] += w5 or 0
            tot["cache_w1h"] += w1 or 0
    tot["messages"] = len(seen)
    tot["model"] = model
    return tot


def compute_cost(tot: dict, usdjpy: float) -> dict:
    usd = (
        tot["input"] * RATE_INPUT
        + tot["output"] * RATE_OUTPUT
        + tot["cache_read"] * RATE_CACHE_READ
        + tot["cache_w5m"] * RATE_CACHE_WRITE_5M
        + tot["cache_w1h"] * RATE_CACHE_WRITE_1H
    ) / 1_000_000
    return {"usd": usd, "jpy": usd * usdjpy, "usdjpy": usdjpy}


def notify(jpy: float, usd: float, usdjpy: float) -> None:
    title = "Fable 利用額"
    body = f"このセッション ¥{jpy:,.0f}"
    subtitle = f"${usd:,.2f}  @ ¥{usdjpy:.1f}/$"
    script = (
        f'display notification "{body}" with title "{title}" subtitle "{subtitle}"'
    )
    try:
        subprocess.run(["osascript", "-e", script], timeout=5,
                       capture_output=True)
    except Exception:
        pass


def read_hook_stdin() -> dict:
    if sys.stdin.isatty():
        return {}
    try:
        raw = sys.stdin.read()
        return json.loads(raw) if raw.strip() else {}
    except Exception:
        return {}


def main() -> int:
    ap = argparse.ArgumentParser(description="Fable 5 従量課金シミュレータ")
    ap.add_argument("--transcript", help="セッション jsonl のパス")
    ap.add_argument("--json", action="store_true", help="内訳を JSON 出力(通知しない)")
    ap.add_argument("--no-notify", action="store_true", help="通知せず標準出力のみ")
    args = ap.parse_args()

    hook = read_hook_stdin()
    transcript = _resolve_transcript(args.transcript or hook.get("transcript_path"))
    if not transcript:
        # フックを絶対に失敗させない
        if args.json:
            print("{}")
        return 0

    tot = compute_tokens(transcript)
    usdjpy, src = _usd_jpy()
    cost = compute_cost(tot, usdjpy)

    if args.json:
        print(json.dumps({**tot, **cost, "fx_source": src,
                          "transcript": str(transcript)},
                         ensure_ascii=False, indent=2))
        return 0

    line = (f"Fable このセッション ¥{cost['jpy']:,.0f} "
            f"(${cost['usd']:,.2f} @ ¥{usdjpy:.1f}/$, "
            f"{tot['messages']}応答 / 実モデル {tot['model']})")
    print(line)

    if not args.no_notify:
        notify(cost["jpy"], cost["usd"], usdjpy)
    return 0


if __name__ == "__main__":
    sys.exit(main())
