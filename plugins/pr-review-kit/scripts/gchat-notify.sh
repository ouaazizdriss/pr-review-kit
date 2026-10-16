#!/usr/bin/env bash
# gchat-notify.sh — post a message to ONE Google Chat space through its incoming webhook.
#
#   gchat-notify.sh "plain text message"
#   printf '%s' '<cardsV2 json>' | gchat-notify.sh --json
#
# Dormant while GCHAT_WEBHOOK_URL is unset: prints a notice and exits 0.
# The webhook URL carries a secret token: keep it in the environment, never on the
# command line, and never print it.
set -euo pipefail

URL="${GCHAT_WEBHOOK_URL:-}"
if [ -z "$URL" ]; then
  echo "gchat-notify: GCHAT_WEBHOOK_URL not set — dormant, nothing sent."
  exit 0
fi

mode="text"
if [ "${1:-}" = "--json" ]; then mode="json"; shift; fi
if [ "$mode" = "json" ]; then
  payload=$(cat)
else
  payload=$(printf '%s' "${1:-}" | jq -Rs '{text: .}')
fi

out=$(mktemp); trap 'rm -f "$out"' EXIT
code=$(curl -s -o "$out" -w "%{http_code}" --max-time 20 \
        -X POST -H "Content-Type: application/json; charset=UTF-8" -d "$payload" "$URL")
if [ "$code" = "200" ]; then
  echo "gchat-notify: sent (HTTP 200)"
else
  echo "gchat-notify: FAILED (HTTP $code)"; sed 's/token=[^"&]*/token=<hidden>/g' "$out"
  exit 1
fi
