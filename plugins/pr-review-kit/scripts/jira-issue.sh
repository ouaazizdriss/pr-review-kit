#!/usr/bin/env bash
# jira-issue.sh <KEY> — read-only Jira lookup used for the "ticket" line of a review.
# Prints one JSON object:
#   {key, http, found, url, type, status, statusCategory, resolution, summary, assignee}
#   {key, disabled:true}            when JIRA_BASE is not configured
#   {key, http, found:false, error} on failure (404 = ticket does not exist)
# Needs JIRA_EMAIL (config) and JIRA_PAT (environment). Never writes to Jira.
set -uo pipefail
. "$(dirname "$0")/lib/common.sh"
prr_load --no-auth
KEY="${1:?usage: jira-issue.sh <KEY>}"

if [ -z "${JIRA_BASE:-}" ]; then jq -cn --arg k "$KEY" '{key:$k, disabled:true}'; exit 0; fi
[ -n "${JIRA_EMAIL:-}" ] || prr_json_error "JIRA_EMAIL is empty in config.env"
[ -n "${JIRA_PAT:-}" ] || prr_json_error "JIRA_PAT is not set in the environment"

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
CODE=$(curl -s -m 30 -o "$TMP" -w '%{http_code}' -u "$JIRA_EMAIL:$JIRA_PAT" -H "Accept: application/json" \
  "$JIRA_API/issue/$KEY?fields=summary,status,issuetype,assignee,resolution")

if [ "$CODE" = 200 ]; then
  jq -c --arg k "$KEY" --arg url "$JIRA_BROWSE/$KEY" '{key:$k, http:200, found:true, url:$url,
      type:.fields.issuetype.name, status:.fields.status.name,
      statusCategory:.fields.status.statusCategory.key,
      resolution:(.fields.resolution.name // null), summary:.fields.summary,
      assignee:(.fields.assignee.displayName // null)}' "$TMP"
else
  jq -cn --arg k "$KEY" --arg c "$CODE" --arg url "$JIRA_BROWSE/$KEY" \
    '{key:$k, http:($c|tonumber? // 0), found:false, url:$url,
      error:(if $c == "404" then "ticket not found" elif $c == "401" or $c == "403" then "Jira authentication failed" else "Jira request failed" end)}'
fi
