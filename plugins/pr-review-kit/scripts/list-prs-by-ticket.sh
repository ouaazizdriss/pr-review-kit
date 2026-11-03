#!/usr/bin/env bash
#
# list-prs-by-ticket.sh
#
# Connects to Azure DevOps (org/project from config.env), enumerates every repo,
# fetches its pull requests, extracts the Jira ticket id from each PR's title or
# source branch, and prints the PRs grouped by ticket id.
#
# For each ticket id it lists every PR as:
#   #<id>  <title>  [<repo>]  <status>  <source>→<target>
#
# READ-ONLY: only HTTP GET calls are made. Nothing is pushed or modified.
#
# Requirements: bash, curl, jq, AZURE_DEVOPS_PAT exported. whiptail for the UI.
#
# Usage:
#   ./list-prs-by-ticket.sh [-s status] [-t ticket] [-c creator] [-r reviewer] [-d days] [-p repo] [-u] [status]
#
#     -s status    active | completed | abandoned | all   (default: active)
#     -t tickets   only PRs for these Jira ticket(s). Accepts a comma- and/or
#                  space-separated list, e.g. -t "ABC-123,XYZ-45" or
#                  -t "123 45". Case-insensitive; a bare number matches that
#                  number under any allowed prefix. A single ticket still works.
#     -c creator   only PRs whose creator's email or display name contains this
#                  text (case-insensitive). e.g. -c "jdoe" or -c "jane@x.com"
#     -r reviewer  only PRs having a reviewer whose email or display name contains
#                  this text (case-insensitive). e.g. -r "dupont"
#     -d days      only PRs created within the last N days
#     -p repo      only scan repositories whose name contains this text (case-
#                  insensitive), within the allow-list. e.g. -p portal or -p sql
#     -u, --ui     force the interactive whiptail UI
#     -h, --help   show this help
#
#   Run with NO arguments to launch the interactive UI (when whiptail and a
#   terminal are available). Passing any flag runs non-interactively, e.g.
#     ./list-prs-by-ticket.sh active
#
set -euo pipefail

. "$(dirname "$0")/lib/common.sh"
prr_load --no-auth
ORG="$ADO_ORG"
PROJECT="$ADO_PROJECT"
API="${ADO_API_VERSION:-7.0}"
BASE="https://dev.azure.com/${ORG}/${PROJECT}/_apis/git"
PAGE_SIZE=100

STATUS="active"
TICKET=""
CREATOR=""
REVIEWER=""
DAYS=""
REPO_FILTER=""

# Jira ticket pattern (overridable via TICKET_KEY_REGEX in config.env)
TICKET_RE="$TICKET_KEY_REGEX"

# Only these repositories are ever scanned (any other repo in the project is
# ignored). The list is the workspace repos.allowlist.
REPO_ALLOWLIST="$(grep -vE '^\s*(#|$)' "$REPO_ALLOWLIST_FILE" | sed 's/\s*$//')"


usage() { sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'; }

ARGC=$#          # remember whether we were invoked with no arguments
UI_FORCE=0

# Pull out long options (getopts only handles short ones) before parsing.
ARGS=()
for a in "$@"; do
  case "$a" in
    --help) usage; exit 0 ;;
    --ui)   UI_FORCE=1 ;;
    *)      ARGS+=("$a") ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

while getopts ":s:t:c:r:d:p:uh" opt; do
  case "$opt" in
    s) STATUS="$OPTARG" ;;
    t) TICKET="$OPTARG" ;;
    c) CREATOR="$OPTARG" ;;
    r) REVIEWER="$OPTARG" ;;
    d) DAYS="$OPTARG" ;;
    p) REPO_FILTER="$OPTARG" ;;
    u) UI_FORCE=1 ;;
    h) usage; exit 0 ;;
    :) echo "ERROR: option -$OPTARG requires an argument." >&2; exit 2 ;;
    \?) echo "ERROR: unknown option -$OPTARG." >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
# Backwards-compatible bare positional status argument.
[ $# -gt 0 ] && STATUS="$1"

if [ -z "${AZURE_DEVOPS_PAT:-}" ]; then
  echo "ERROR: AZURE_DEVOPS_PAT is not set in the environment." >&2
  exit 1
fi
for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is required but not installed." >&2; exit 1; }
done

# Decide whether to run the interactive UI: no args (or -u/--ui), whiptail
# present, and we have a real terminal on stdin/stdout.
UI_MODE=0
if { [ "$ARGC" -eq 0 ] || [ "$UI_FORCE" -eq 1 ]; } \
   && command -v whiptail >/dev/null 2>&1 && [ -t 0 ] && [ -t 1 ]; then
  UI_MODE=1
fi

# ---- Interactive UI: collect the filters via whiptail -----------------------
if [ "$UI_MODE" -eq 1 ]; then
  STATUS=$(whiptail --title "PRs by Jira ticket" \
    --radiolist "Pull request status to fetch:" 13 60 4 \
      active    "Active only"      ON  \
      all       "All PRs"          OFF \
      completed "Completed only"   OFF \
      abandoned "Abandoned only"   OFF \
    3>&1 1>&2 2>&3) || { echo "Cancelled." >&2; exit 0; }

  TICKET=$(whiptail --title "PRs by Jira ticket" \
    --inputbox "Jira ticket filter — one or a list, e.g. ABC-123,XYZ-45\n(or bare numbers 123 45). Leave blank for all tickets." 10 64 "" \
    3>&1 1>&2 2>&3) || { echo "Cancelled." >&2; exit 0; }

  CREATOR=$(whiptail --title "PRs by Jira ticket" \
    --inputbox "Creator filter — email or display name substring.\nLeave blank for any creator." 10 64 "" \
    3>&1 1>&2 2>&3) || { echo "Cancelled." >&2; exit 0; }

  REVIEWER=$(whiptail --title "PRs by Jira ticket" \
    --inputbox "Reviewer filter — email or display name substring.\nLeave blank for any reviewer." 10 64 "" \
    3>&1 1>&2 2>&3) || { echo "Cancelled." >&2; exit 0; }

  REPO_FILTER=$(whiptail --title "PRs by Jira ticket" \
    --inputbox "Repository filter — only scan repos whose name contains this text.\nLeave blank to scan the whole allow-list." 10 64 "" \
    3>&1 1>&2 2>&3) || { echo "Cancelled." >&2; exit 0; }

  while :; do
    DAYS=$(whiptail --title "PRs by Jira ticket" \
      --inputbox "Only PRs created within the last N days.\nLeave blank for all time." 10 64 "" \
      3>&1 1>&2 2>&3) || { echo "Cancelled." >&2; exit 0; }
    [ -z "$DAYS" ] && break
    [[ "$DAYS" =~ ^[0-9]+$ ]] && break
    whiptail --title "Invalid value" --msgbox "Days must be a whole number." 8 50
  done
fi

if [ -n "$DAYS" ] && ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: -d days must be a positive integer." >&2; exit 2
fi

# Cutoff epoch for the days filter (0 = no time filter).
CUTOFF=0
WINDOW="all time"
if [ -n "$DAYS" ]; then
  CUTOFF=$(date -d "${DAYS} days ago" +%s)
  WINDOW="last ${DAYS} day(s)"
fi
# Lower-cased needles for the jq matches (empty = no filter on that field).
CREATOR_LC=$(printf '%s' "$CREATOR" | tr '[:upper:]' '[:lower:]')
REVIEWER_LC=$(printf '%s' "$REVIEWER" | tr '[:upper:]' '[:lower:]')
REPO_FILTER_LC=$(printf '%s' "$REPO_FILTER" | tr '[:upper:]' '[:lower:]')

# Ticket filter: accept a list (comma- and/or space-separated). Each entry is
# either a full id (ABC-123, case-insensitive) or a bare number (123, which
# matches that number under any allowed prefix). Build two newline-separated
# sets used by scan_repos: exact ids and bare numbers.
TICKET_IDS=""     # full uppercase ids to match exactly, one per line
TICKET_NUMS=""    # bare numbers to match against the ticket's number part
if [ -n "$TICKET" ]; then
  _tk_norm=$(printf '%s' "$TICKET" | tr ',;' '  ' | tr '[:lower:]' '[:upper:]')
  for _tk in $_tk_norm; do
    if [[ "$_tk" =~ ^[0-9]+$ ]]; then
      TICKET_NUMS+="${_tk}"$'\n'
    else
      TICKET_IDS+="${_tk}"$'\n'
    fi
  done
fi

AUTH=$(printf ":%s" "$AZURE_DEVOPS_PAT" | base64 -w0)

api_get() {
  local body
  if ! body=$(curl -s --fail-with-body -H "Authorization: Basic ${AUTH}" "$1"); then
    local body_lc=${body,,}
    if [[ "$body_lc" == *"personal access token used has expired"* ]]; then
      echo "ERROR: the Azure DevOps PAT (AZURE_DEVOPS_PAT) has EXPIRED — renew it and re-export it in this shell." >&2
    elif [[ "$body_lc" == *"access denied"* || "$body_lc" == *"tf400813"* || "$body_lc" == *"not authorized"* ]]; then
      echo "ERROR: Azure DevOps rejected the PAT (access denied). Check AZURE_DEVOPS_PAT." >&2
    else
      echo "ERROR: API call failed: $1" >&2
      printf '%s\n' "$body" | head -c 500 >&2
    fi
    return 22
  fi
  printf '%s' "$body"
}

# Working files (auto-cleaned).
TMP=$(mktemp)        # one "<ticket>\t<prId>\t<title>\t<repo>..." line per matched PR
RAW=$(mktemp)        # allow-listed PRs fetched project-wide, one TSV line each
REPORT=$(mktemp)     # rendered, grouped report
trap 'rm -f "$TMP" "$RAW" "$REPORT"' EXIT

if [ "$UI_MODE" -eq 1 ]; then
  whiptail --title "PRs by Jira ticket" --infobox "Fetching pull requests from ${ORG}/${PROJECT} ..." 7 60
else
  {
    echo "Org/Project : ${ORG}/${PROJECT}"
    echo "Status      : ${STATUS}"
    echo "Ticket      : ${TICKET:-(any)}"
    echo "Creator     : ${CREATOR:-(any)}"
    echo "Reviewer    : ${REVIEWER:-(any)}"
    echo "Repo filter : ${REPO_FILTER:-(all allow-listed)}"
    echo "Window      : ${WINDOW}"
    echo "Fetching pull requests ..."
  } >&2
fi

# Fetch every PR in the project in as few HTTP calls as possible: the project-wide
# pullRequests endpoint returns PRs across ALL repositories in one paginated call,
# so we no longer hit each repository separately (that serial per-repo loop was the
# bottleneck). We then keep only allow-listed repos (and honour -p) via jq, and
# apply the creator / reviewer / time-window filters in the same pass.
ALLOW_JSON=$(printf '%s' "$REPO_ALLOWLIST" | jq -R -s 'split("\n") | map(select(length > 0))')

# Repos in scope (allow-list, optionally narrowed by -p) — for the report header.
REPO_COUNT=$(printf '%s' "$ALLOW_JSON" \
  | jq --arg rf "$REPO_FILTER_LC" '[.[] | select($rf == "" or (ascii_downcase | contains($rf)))] | length')

PR_COUNT=0
skip=0
while :; do
  PRS_JSON=$(api_get "${BASE}/pullRequests?searchCriteria.status=${STATUS}&\$top=${PAGE_SIZE}&\$skip=${skip}&api-version=${API}")
  n=$(printf '%s' "$PRS_JSON" | jq '.value | length')
  [ "$n" -eq 0 ] && break

  # PRs seen in scope on this page (allow-list + -p, any creator) — header count.
  seen=$(printf '%s' "$PRS_JSON" \
    | jq --argjson allow "$ALLOW_JSON" --arg rf "$REPO_FILTER_LC" '
        [ .value[]
          | select(.repository.name as $n | $allow | index($n))
          | select($rf == "" or (.repository.name | ascii_downcase | contains($rf))) ] | length')
  PR_COUNT=$((PR_COUNT + seen))

  [ "$UI_MODE" -ne 1 ] && echo "  fetched $((skip + n)) PR(s) from ${ORG}/${PROJECT} ..." >&2

  # Keep allow-listed + -p repos, apply creator/reviewer/window, and emit one TSV
  # line per PR (repo name is the trailing column). Ticket extraction and the -t
  # filter stay in scan_prs below, preserving the exact original semantics.
  printf '%s' "$PRS_JSON" \
    | jq -r --argjson allow "$ALLOW_JSON" --arg rf "$REPO_FILTER_LC" \
            --arg creator "$CREATOR_LC" --arg reviewer "$REVIEWER_LC" --argjson cutoff "$CUTOFF" '
        .value[]
        | select(.repository.name as $n | $allow | index($n))
        | select($rf == "" or (.repository.name | ascii_downcase | contains($rf)))
        | select(
            ($creator == "")
            or ((.createdBy.uniqueName // "" | ascii_downcase) | contains($creator))
            or ((.createdBy.displayName // "" | ascii_downcase) | contains($creator))
          )
        | select(
            ($reviewer == "")
            or (any(.reviewers[]?;
                  ((.uniqueName // "" | ascii_downcase) | contains($reviewer))
                  or ((.displayName // "" | ascii_downcase) | contains($reviewer))))
          )
        | select(
            ($cutoff == 0)
            or ((.creationDate | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) >= $cutoff)
          )
        | [(.pullRequestId|tostring), .title, .sourceRefName, .status, .targetRefName, (.isDraft|tostring), .repository.name]
        | map(tostring | gsub("[[:cntrl:]]"; " "))   # no terminal control characters from API text
        | @tsv' \
    >> "$RAW"

  [ "$n" -lt "$PAGE_SIZE" ] && break
  skip=$((skip + PAGE_SIZE))
done

TOTAL=$(grep -c . "$RAW" || true)

# scan_prs walks the fetched PRs (local, no network): it extracts the Jira ticket
# from each title/branch, applies the -t ticket filter, and appends matches to $TMP.
# In UI mode it emits the whiptail --gauge protocol on stdout; otherwise it is
# silent (the per-page fetch progress above already went to stderr).
scan_prs() {
  local idx=0
  while IFS=$'\t' read -r PR_ID TITLE BRANCH STATUS_PR TARGET ISDRAFT REPO_NAME; do
    [ -z "$PR_ID" ] && continue
    idx=$((idx + 1))

    if [ "$UI_MODE" -eq 1 ]; then
      local pct=0
      [ "$TOTAL" -gt 0 ] && pct=$(( idx * 100 / TOTAL ))
      printf 'XXX\n%d\nProcessing %d/%d: %s #%s\nXXX\n' "$pct" "$idx" "$TOTAL" "$REPO_NAME" "$PR_ID"
    fi

    local ticket src_short tgt_short status_disp
    ticket=$(printf '%s' "$TITLE"  | grep -oE "$TICKET_RE" | head -n1 || true)
    [ -z "$ticket" ] && ticket=$(printf '%s' "$BRANCH" | grep -oE "$TICKET_RE" | head -n1 || true)
    [ -z "$ticket" ] && ticket="(no-ticket)"
    # Ticket filter (-t): keep the PR if its ticket matches any entry of the list —
    # either an exact id, or a bare number against the number part.
    if [ -n "${TICKET_IDS}${TICKET_NUMS}" ]; then
      local keep=0
      if [ -n "$TICKET_IDS" ] && printf '%s' "$TICKET_IDS" | grep -qxF "$ticket"; then
        keep=1
      fi
      if [ "$keep" -eq 0 ] && [ -n "$TICKET_NUMS" ] \
         && printf '%s' "$TICKET_NUMS" | grep -qxF "${ticket##*-}"; then
        keep=1
      fi
      [ "$keep" -eq 1 ] || continue
    fi
    # Short branch names (strip refs/heads/) and a status that flags drafts.
    src_short=${BRANCH#refs/heads/}
    tgt_short=${TARGET#refs/heads/}
    status_disp="$STATUS_PR"
    [ "$ISDRAFT" = "true" ] && status_disp="${STATUS_PR} (draft)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ticket" "$PR_ID" "$TITLE" "$REPO_NAME" "$status_disp" "$src_short" "$tgt_short" >> "$TMP"
  done < "$RAW"
}

if [ "$UI_MODE" -eq 1 ]; then
  scan_prs | whiptail --title "PRs by Jira ticket" --gauge "Processing pull requests ..." 8 70 0
else
  scan_prs
fi

MATCHED=$(wc -l < "$TMP" | tr -d ' ')

# emit_report renders the grouped report to stdout.
emit_report() {
  echo "Org/Project : ${ORG}/${PROJECT}"
  echo "Status      : ${STATUS}    Ticket: ${TICKET:-(any)}    Creator: ${CREATOR:-(any)}    Reviewer: ${REVIEWER:-(any)}    Repo: ${REPO_FILTER:-(all)}    Window: ${WINDOW}"
  echo "Scanned ${REPO_COUNT} repo(s), ${PR_COUNT} PR(s) seen, ${MATCHED} matched the filters."
  echo "=================================================================="

  local t TICKETS
  TICKETS=$(cut -f1 "$TMP" | sort -u | grep -v '^(no-ticket)$' || true)
  for t in $TICKETS; do
    echo
    echo "### ${t}"
    awk -F'\t' -v t="$t" '$1==t { printf "  - #%s  %s  [%s]  %s  %s→%s\n", $2, $3, $4, $5, $6, $7 }' "$TMP" | sort -t'#' -k2 -n
  done

  if grep -q '^(no-ticket)' "$TMP"; then
    echo
    echo "### (no Jira ticket found)"
    awk -F'\t' '$1=="(no-ticket)" { printf "  - #%s  %s  [%s]  %s  %s→%s\n", $2, $3, $4, $5, $6, $7 }' "$TMP"
  fi
}

# emit_pretty renders a colourised, structured report for an interactive terminal.
# Same per-PR token order as the plain report (so copied lines stay usable), just
# coloured and with clearer section headers + a per-ticket count.
emit_pretty() {
  local C_RESET C_BOLD C_DIM C_TICKET C_ID C_REPO C_ACT C_DRAFT C_DONE C_ABAND C_RULE
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_TICKET=$'\033[1;36m'; C_ID=$'\033[1;33m'; C_REPO=$'\033[35m'
  C_ACT=$'\033[32m'; C_DRAFT=$'\033[33m'; C_DONE=$'\033[34m'; C_ABAND=$'\033[31m'
  C_RULE=$'\033[2m'

  local W rule; W=$(tput cols 2>/dev/null || echo 100); [ "$W" -gt 120 ] && W=120
  rule=$(printf '─%.0s' $(seq 1 "$W"))

  printf '%sPRs by Jira ticket — %s/%s%s\n' "$C_BOLD" "$ORG" "$PROJECT" "$C_RESET"
  printf '%sfilters%s  status=%s  ticket=%s  creator=%s  reviewer=%s  repo=%s  window=%s\n' \
    "$C_DIM" "$C_RESET" "$STATUS" "${TICKET:-any}" "${CREATOR:-any}" "${REVIEWER:-any}" "${REPO_FILTER:-all}" "$WINDOW"
  printf '%s%s matched%s  %s· %s seen · %s repo(s)%s\n' \
    "$C_BOLD" "$MATCHED" "$C_RESET" "$C_DIM" "$PR_COUNT" "$REPO_COUNT" "$C_RESET"
  printf '%s%s%s\n' "$C_RULE" "$rule" "$C_RESET"

  local t cnt TICKETS
  local colorize='{
      st=$5; c=cA;
      if (st ~ /draft/) c=cD; else if (st ~ /abandoned/) c=cX; else if (st ~ /completed/) c=cC;
      printf "  - %s#%s%s  %s  %s[%s]%s  %s%s%s  %s%s→%s%s\n", id,$2,rs, $3, rp,$4,rs, c,st,rs, dm,$6,$7,rs
    }'
  TICKETS=$(cut -f1 "$TMP" | sort -u | grep -v '^(no-ticket)$' || true)
  for t in $TICKETS; do
    cnt=$(awk -F'\t' -v t="$t" '$1==t' "$TMP" | grep -c . || true)
    printf '\n%s▸ %s%s %s(%s)%s\n' "$C_TICKET" "$t" "$C_RESET" "$C_DIM" "$cnt" "$C_RESET"
    awk -F'\t' -v t="$t" '$1==t' "$TMP" | sort -t$'\t' -k2 -n \
      | awk -F'\t' -v id="$C_ID" -v rs="$C_RESET" -v rp="$C_REPO" -v dm="$C_DIM" \
            -v cA="$C_ACT" -v cD="$C_DRAFT" -v cC="$C_DONE" -v cX="$C_ABAND" "$colorize"
  done

  if grep -q '^(no-ticket)' "$TMP"; then
    cnt=$(awk -F'\t' '$1=="(no-ticket)"' "$TMP" | grep -c . || true)
    printf '\n%s▸ (no Jira ticket)%s %s(%s)%s\n' "$C_TICKET" "$C_RESET" "$C_DIM" "$cnt" "$C_RESET"
    awk -F'\t' '$1=="(no-ticket)"' "$TMP" | sort -t$'\t' -k2 -n \
      | awk -F'\t' -v id="$C_ID" -v rs="$C_RESET" -v rp="$C_REPO" -v dm="$C_DIM" \
            -v cA="$C_ACT" -v cD="$C_DRAFT" -v cC="$C_DONE" -v cX="$C_ABAND" "$colorize"
  fi
}

emit_report > "$REPORT"

if [ "$UI_MODE" -eq 1 ]; then
  whiptail --title "PRs by Jira ticket  (${MATCHED} matched)" --scrolltext --textbox "$REPORT" 0 0
fi

# Interactive terminal → colourised layout; piped / redirected / NO_COLOR → the
# plain report unchanged (so batch-review pasting and parsing stay intact).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  emit_pretty
else
  cat "$REPORT"
fi
