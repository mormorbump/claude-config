#!/bin/bash
# digest-runner.sh — Run a digest prompt via claude -p and post to Discord
# Usage: digest-runner.sh <job-name>
#   job-name: ai-intelligence | hiphop | guitar-gear

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JOB_NAME="${1:?Usage: digest-runner.sh <job-name>}"
PROMPT_FILE="${SCRIPT_DIR}/prompts/${JOB_NAME}.txt"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/${JOB_NAME}-$(date +%Y%m%d).log"

# Load env
source "${SCRIPT_DIR}/.env"

# Validate
if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE" | tee -a "$LOG_FILE"
  exit 1
fi

echo "=== ${JOB_NAME} digest started at $(date) ===" >> "$LOG_FILE"

# Run claude -p with the prompt
PROMPT="$(cat "$PROMPT_FILE")"
RESULT=$(claude -p \
  --model sonnet \
  --allowedTools "WebSearch WebFetch Read" \
  --permission-mode dontAsk \
  --no-session-persistence \
  "$PROMPT" 2>>"$LOG_FILE") || {
  echo "ERROR: claude -p failed" >> "$LOG_FILE"
  exit 1
}

echo "claude -p completed, output length: ${#RESULT}" >> "$LOG_FILE"

# Post to Discord (handle 2000 char limit by splitting)
post_to_discord() {
  local content="$1"
  local response
  response=$(curl -s -w "\n%{http_code}" -X POST \
    "https://discord.com/api/v10/channels/${DISCORD_CHANNEL_ID}/messages" \
    -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg content "$content" '{content: $content}')")

  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
    echo "Discord post OK (HTTP ${http_code})" >> "$LOG_FILE"
  else
    echo "Discord post FAILED (HTTP ${http_code}): ${body}" >> "$LOG_FILE"
    return 1
  fi
}

# Split message if > 1900 chars (leave margin for safety)
MAX_LEN=1900
if [[ ${#RESULT} -le $MAX_LEN ]]; then
  post_to_discord "$RESULT"
else
  # Split by double newline (paragraph) boundaries
  REMAINING="$RESULT"
  PART=""
  PART_NUM=1

  while IFS= read -r -d '' CHUNK || [[ -n "$CHUNK" ]]; do
    if [[ $(( ${#PART} + ${#CHUNK} + 2 )) -gt $MAX_LEN ]]; then
      if [[ -n "$PART" ]]; then
        post_to_discord "$PART"
        PART_NUM=$((PART_NUM + 1))
        sleep 1  # Rate limit avoidance
      fi
      PART="$CHUNK"
    else
      if [[ -n "$PART" ]]; then
        PART="${PART}

${CHUNK}"
      else
        PART="$CHUNK"
      fi
    fi
  done < <(printf '%s' "$RESULT" | sed 's/\n\n/\x00/g')

  # Post remaining
  if [[ -n "$PART" ]]; then
    post_to_discord "$PART"
  fi
fi

echo "=== ${JOB_NAME} digest completed at $(date) ===" >> "$LOG_FILE"
