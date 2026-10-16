#!/usr/bin/env bash
# wfa-reminder.sh [--dry-run] — post the "waiting for the author" reminder to Google Chat.
#
# Lists every active, allow-listed PR where my vote is -5 as a Chat card: the PR id
# links to the PR, then the ticket and the author's name. Pings the space with
# <users/all> unless WFA_MENTION is set to something else (empty = no ping).
# Read-only against Azure DevOps; writes only to the webhook; sends NOTHING when the
# list is empty. --dry-run prints the card instead of sending it.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib/common.sh"
prr_load
ME=$(prr_reviewer_id)
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
ALLOW=$(grep -vE '^\s*(#|$)' "$REPO_ALLOWLIST_FILE" | sed 's/\s*$//' | jq -R . | jq -sc .)
MENTION="${WFA_MENTION-<users/all>}"

human() { local n="$1"; if [[ "$n" == *@* ]]; then n="${n%@*}"; n="${n//./ }"; fi
  echo "$n" | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) tolower(substr($i,2))}; print}'; }

rows=$(mktemp); trap 'rm -f "$rows"' EXIT
skip=0
while :; do
  r=$(prr_get_list "$ADO_BASE/pullrequests?searchCriteria.status=active&\$top=100&\$skip=$skip&api-version=$ADO_API_VERSION") || break
  echo "$r" | jq -r --arg me "$ME" --argjson a "$ALLOW" '.value[] | . as $p
     | select(($a | index($p.repository.name)) != null)
     | ($p.reviewers[]? | select(.id == $me) | .vote) as $v | select($v == -5)
     | [($p.pullRequestId|tostring), $p.repository.name, $p.createdBy.displayName, $p.title, $p.sourceRefName] | @tsv' >> "$rows"
  [ "$(echo "$r" | jq '.value|length')" -lt 100 ] && break
  skip=$((skip+100))
done
sort -t$'\t' -k1 -n -o "$rows" "$rows"

n=$(grep -c . "$rows" || true)
if [ "$n" -eq 0 ]; then echo "wfa-reminder: no PR waiting for its author — nothing sent."; exit 0; fi

if [ "${REVIEW_LANGUAGE}" = fr ]; then
  T_TITLE="🔔 PRs en attente de l’auteur"; T_SUB="$n PR — merci de traiter les retours de revue puis de relancer la revue"; T_NOTICKET="(sans ticket)"
else
  T_TITLE="🔔 PRs waiting for their author"; T_SUB="$n PR — please address the review points, then ask for a new review"; T_NOTICKET="(no ticket)"
fi
# optional per-team wording (config.env); {n} in WFA_SUBTITLE is replaced by the PR count
[ -n "${WFA_TITLE:-}" ] && T_TITLE="$WFA_TITLE"
[ -n "${WFA_SUBTITLE:-}" ] && T_SUB="${WFA_SUBTITLE//\{n\}/$n}"
[ -n "${WFA_NO_TICKET:-}" ] && T_NOTICKET="$WFA_NO_TICKET"

widgets=$(while IFS=$'\t' read -r id repo author title branch; do
    tk=$(prr_ticket_of "$title" "$branch"); [ -z "$tk" ] && tk="—"
    url=$(prr_pr_url "$repo" "$id")
    jira=""; [ "$tk" != "—" ] && [ -n "${JIRA_BROWSE:-}" ] && jira="$JIRA_BROWSE/$tk"
    jq -n --arg id "$id" --arg repo "$repo" --arg tk "$tk" --arg au "$(human "$author")" \
          --arg url "$url" --arg jira "$jira" --arg nt "$T_NOTICKET" \
      '{decoratedText:{
          topLabel: $repo,
          text: ("<a href=\""+$url+"\">#"+$id+"</a>"
                 + (if $tk == "—" then "   ·   " + $nt
                    elif $jira == "" then "   ·   " + $tk
                    else "   ·   <a href=\""+$jira+"\">"+$tk+"</a>" end)),
          bottomLabel: ("👤 "+$au),
          wrapText: true }}'
  done < "$rows" | jq -s '.')

payload=$(jq -n --argjson w "$widgets" --arg t "$T_TITLE" --arg sub "$T_SUB" --arg m "$MENTION" '
  { text: $m,
    cardsV2: [ { cardId: "wfa-reminder",
      card: { header: {title: $t, subtitle: $sub}, sections: [ { widgets: $w } ] } } ] }')

if [ "$DRY" = 1 ]; then echo "$payload"; exit 0; fi
printf '%s' "$payload" | "$DIR/gchat-notify.sh" --json
