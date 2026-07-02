#!/bin/bash
# PostToolUse 計測フック（fail-open）
# 設計思想: 計測はエージェントの動作を絶対に妨げない。
#   - trap は EXIT のみ（ERR trapは冗長なので使わない）。最終的に必ず exit 0。
#   - 全操作を || true 等で保護し、壊れたJSON・空入力・jq不在でもクラッシュしない。
#   - stdout/stderrには何も出力しない（PostToolUseの出力は無視される前提だが念のため）。
trap 'exit 0' EXIT

main() {
  local METRICS_DIR="$HOME/.claude/metrics"
  local input
  input="$(cat 2>/dev/null)" || return 0
  [ -z "$input" ] && return 0

  command -v jq >/dev/null 2>&1 || return 0

  # 入力JSONが壊れていないか軽く検査（壊れていれば何もせず終了）
  echo "$input" | jq -e . >/dev/null 2>&1 || return 0

  mkdir -p "$METRICS_DIR" 2>/dev/null || return 0

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || return 0

  local month
  month="$(date +%Y-%m 2>/dev/null)" || return 0
  local outfile="$METRICS_DIR/usage-${month}.jsonl"

  # cwd の $HOME 部分を ~ に置換して短縮
  local raw_cwd
  raw_cwd="$(echo "$input" | jq -r '.cwd // empty' 2>/dev/null)" || raw_cwd=""
  local cwd_short="$raw_cwd"
  if [ -n "$HOME" ] && [ -n "$raw_cwd" ]; then
    case "$raw_cwd" in
      "$HOME"/*) cwd_short="~${raw_cwd#"$HOME"}" ;;
      "$HOME") cwd_short="~" ;;
    esac
  fi
  # 異常に長い値の保険（4KB保証の一環。500文字程度で十分safe）
  if [ ${#cwd_short} -gt 500 ]; then
    cwd_short="${cwd_short:0:500}...(truncated)"
  fi

  local line
  line="$(
    jq -nc \
      --arg ts "$ts" \
      --argjson input "$input" \
      --arg cwd_short "$cwd_short" \
      '
      ($input.tool_name // null) as $tool_name
      | {
          ts: $ts,
          session_id: ($input.session_id // null),
          cwd: (if $cwd_short == "" then null else $cwd_short end),
          tool_name: $tool_name,
          skill: (if $tool_name == "Skill" then ($input.tool_input.skill // null) else null end),
          subagent_type: (if ($tool_name == "Agent" or $tool_name == "Task") then ($input.tool_input.subagent_type // null) else null end),
          error: (
            ($input.tool_response? // null) as $r
            | if ($r | type) == "object"
                 and ((($r.is_error? // false) == true) or (($r.error? // null) != null))
              then true else null end
          )
        }
      | with_entries(select(.value != null and .value != ""))
      ' 2>/dev/null
  )" || return 0

  [ -z "$line" ] && return 0

  # 1行4KB未満の保証。超える場合はtool_name等最小限のフィールドに縮退。
  if [ "${#line}" -ge 4096 ]; then
    line="$(
      jq -nc --arg ts "$ts" --arg tool_name "$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null)" \
        '{ts: $ts, tool_name: $tool_name, truncated: true}' 2>/dev/null
    )" || return 0
    [ -z "$line" ] && return 0
  fi

  # PIPE_BUF内に収まるサイズでのアトミック追記
  printf '%s\n' "$line" >> "$outfile" 2>/dev/null || true

  cleanup_old_metrics "$METRICS_DIR"
  return 0
}

# 低確率（約1/100）で古いmetricsファイルを掃除する。全操作 fail-open。
cleanup_old_metrics() {
  local dir="$1"
  [ -d "$dir" ] || return 0

  if (( RANDOM % 100 == 0 )); then
    # 6ヶ月(180日)超の usage-*.jsonl を gzip 圧縮
    find "$dir" -name 'usage-*.jsonl' -mtime +180 -print0 2>/dev/null | \
      xargs -0 -I{} gzip -f "{}" 2>/dev/null || true

    # 12ヶ月(365日)超の usage-*.jsonl* (.gz含む) を削除
    find "$dir" -name 'usage-*.jsonl*' -mtime +365 -delete 2>/dev/null || true
  fi
  return 0
}

main
exit 0
