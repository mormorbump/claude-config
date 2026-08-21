#!/usr/bin/env python3
"""PostToolUse hook: mdファイルへの書き込み内容をNGワード(会話文脈の混入表現など)と照合し、
ヒットしたら decision:block でClaudeに削除を促すフィードバックを返す。

- パターン定義: ~/.claude/hooks/ng-words.txt (1行1正規表現、#はコメント)
- 意図的に残す行は <!-- ng-ok --> を行内に付けるとスキップされる
- 対象: Write の content / Edit の new_string (書き込んだ差分のみ。既存行には反応しない)
"""
import json
import os
import re
import sys

TARGET_EXT = re.compile(r"\.(md|mdx|markdown)$", re.IGNORECASE)
PATTERN_FILE = os.path.expanduser("~/.claude/hooks/ng-words.txt")
MAX_REPORT = 5
SKIP_MARKER = "ng-ok"


def load_patterns():
    patterns = []
    try:
        with open(PATTERN_FILE, encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                try:
                    patterns.append(re.compile(line))
                except re.error:
                    print(f"[ng-words-check] invalid regex skipped: {line}", file=sys.stderr)
    except FileNotFoundError:
        pass
    return patterns


def collect_texts(tool_input):
    texts = []
    if isinstance(tool_input.get("content"), str):
        texts.append(tool_input["content"])
    if isinstance(tool_input.get("new_string"), str):
        texts.append(tool_input["new_string"])
    for edit in tool_input.get("edits") or []:
        ns = edit.get("new_string") if isinstance(edit, dict) else None
        if isinstance(ns, str):
            texts.append(ns)
    return texts


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return
    if data.get("tool_name") not in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        return
    tool_input = data.get("tool_input") or {}
    file_path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
    if not TARGET_EXT.search(file_path):
        return

    texts = collect_texts(tool_input)
    if not texts:
        return
    patterns = load_patterns()
    if not patterns:
        return

    hits = []
    for text in texts:
        for line in text.splitlines():
            if SKIP_MARKER in line:
                continue
            for pat in patterns:
                m = pat.search(line)
                if m:
                    hits.append((line.strip()[:120], pat.pattern[:60]))
                    break

    if not hits:
        return

    shown = hits[:MAX_REPORT]
    detail = "\n".join(f'- 「{line}」 (pattern: {pat})' for line, pat in shown)
    more = f"\n(他{len(hits) - MAX_REPORT}件)" if len(hits) > MAX_REPORT else ""
    reason = (
        f"[ng-words-check] {os.path.basename(file_path)} への書き込みにNG表現を検出:\n"
        f"{detail}{more}\n"
        "会話の経緯への参照や「〜の話はこのmdには含めない」のような否定的スコープ宣言は、"
        "ドキュメントの読者にとって無意味な会話文脈の混入。意図がなければ該当行を削除・書き直すこと。"
        "意図的に残す場合はその行に <!-- ng-ok --> を付けて再実行する。"
    )
    print(json.dumps({
        "decision": "block",
        "reason": reason,
        "systemMessage": f"⚠ NGワード検出: {os.path.basename(file_path)} ({len(hits)}件) — Claudeに修正を指示済み",
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
