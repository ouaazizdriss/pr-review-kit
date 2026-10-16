#!/usr/bin/env bash
#
# check-pr-deployed.sh
#
# Takes one (or several) Jira ticket id(s), finds every Azure DevOps pull request
# for that ticket (org/project from config.env), then tells you — repo by repo —
# whether each PR's change is actually present in a given production release
# (default: release/1.2.0).
#
# "Present in the release" is answered from the real git history of each repo,
# using TWO independent signals so cherry-picks are not missed:
#
#   1. ANCESTRY   — the PR's merge commit is an ancestor of the release ref
#                   (git merge-base --is-ancestor). This is the ground truth for
#                   merges / fast-forwards.
#   2. PR-ID      — a commit reachable from the release ref carries the Azure
#                   "Merged PR <id>:" marker. This catches the change even when it
#                   reached the release via a cherry-pick / re-merge (different SHA),
#                   which pure ancestry cannot see.
#
# Each PR gets a binary verdict: ✅ IN <release> (either signal fires) or ❌ NOT IN
# (not merged, merged to another branch, or the release ref is absent from the repo).
#
# READ-ONLY against Azure DevOps: only HTTP GET calls and read-only git clone/fetch.
# Nothing is pushed, voted, or commented.
#
# Requirements: bash, curl, jq, git, AZURE_DEVOPS_PAT exported.
#
# Usage:
#   ./check-pr-deployed.sh <ticket>[,<ticket>...] [release-ref]
#   ./check-pr-deployed.sh -t <tickets> [-r release-ref] [-p repo-substr] [-a]
#
#     -t tickets       one or a comma/space-separated list. Full ids (ABC-123)
#                      or bare numbers (123, matched under any allowed prefix).
#     -r release-ref   the production release to test against. Branch or tag.
#                      Default: release/1.2.0
#     -p repo-substr   only look at repos whose name contains this substring.
#     -a               refresh caches: re-fetch every repo even if already cached.
#     -h, --help       show this help.
#
# Examples:
#   ./check-pr-deployed.sh ABC-123
#   ./check-pr-deployed.sh ABC-123,XYZ-45 release/1.2.0
#   ./check-pr-deployed.sh -t 123 -r release/1.2.0 -p portal
#
set -euo pipefail

. "$(dirname "$0")/lib/common.sh"
prr_load --no-auth
ORG="$ADO_ORG"
PROJECT="$ADO_PROJECT"
API="${ADO_API_VERSION:-7.0}"
BASE="https://dev.azure.com/${ORG}/${PROJECT}/_apis/git"
REPO_BASE="https://dev.azure.com/${ORG}/${PROJECT}/_git"
PAGE_SIZE=100

# Where bare clones are cached between runs (commit graph only — no file blobs).
CACHE="${DEPLOY_CHECK_CACHE:-$HOME/.cache/pr-review-kit/deploy-check}"

TICKET=""
RELEASE_REF="${DEFAULT_RELEASE_REF:-}"
REPO_FILTER=""
REFRESH=0

TICKET_RE="$TICKET_KEY_REGEX"

# Same allow-list as list-prs-by-ticket.sh — only these repos are ever considered.
REPO_ALLOWLIST="$(grep -vE '^\s*(#|$)' "$REPO_ALLOWLIST_FILE" | sed 's/\s*$//')"


usage() { sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//'; }

# ---- arg parsing ------------------------------------------------------------
ARGS=()
for a in "$@"; do
  case "$a" in
    --help) usage; exit 0 ;;
    *)      ARGS+=("$a") ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

while getopts ":t:r:p:ah" opt; do
  case "$opt" in
    t) TICKET="$OPTARG" ;;
    r) RELEASE_REF="$OPTARG" ;;
    p) REPO_FILTER="$OPTARG" ;;
    a) REFRESH=1 ;;
    h) usage; exit 0 ;;
    :) echo "ERROR: option -$OPTARG requires an argument." >&2; exit 2 ;;
    \?) echo "ERROR: unknown option -$OPTARG." >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
# Backwards-compatible positionals: <tickets> [release-ref]
[ -z "$TICKET" ] && [ $# -gt 0 ] && { TICKET="$1"; shift; }
[ $# -gt 0 ] && RELEASE_REF="$1"

if [ -z "$RELEASE_REF" ]; then
  echo "ERROR: a release ref is required (-r release/X.Y.Z, or DEFAULT_RELEASE_REF in config.env)." >&2
  exit 2
fi
if [ -z "$TICKET" ]; then
  echo "ERROR: a Jira ticket (or list) is required. e.g. $0 ABC-123" >&2
  exit 2
fi
if [ -z "${AZURE_DEVOPS_PAT:-}" ]; then
  echo "ERROR: AZURE_DEVOPS_PAT is not set in the environment." >&2
  exit 1
fi
for bin in curl jq git; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is required but not installed." >&2; exit 1; }
done

REPO_FILTER_LC=$(printf '%s' "$REPO_FILTER" | tr '[:upper:]' '[:lower:]')

# Ticket filter sets (same semantics as list-prs-by-ticket.sh).
TICKET_IDS=""
TICKET_NUMS=""
_tk_norm=$(printf '%s' "$TICKET" | tr ',;' '  ' | tr '[:lower:]' '[:upper:]')
for _tk in $_tk_norm; do
  if [[ "$_tk" =~ ^[0-9]+$ ]]; then TICKET_NUMS+="${_tk}"$'\n'; else TICKET_IDS+="${_tk}"$'\n'; fi
done

AUTH=$(printf ":%s" "$AZURE_DEVOPS_PAT" | base64 -w0)
GIT_AUTH=(-c "http.extraHeader=AUTHORIZATION: Basic ${AUTH}")

api_get() {
  local body
  if ! body=$(curl -s --fail-with-body -H "Authorization: Basic ${AUTH}" "$1"); then
    local body_lc=${body,,}
    if [[ "$body_lc" == *"personal access token used has expired"* ]]; then
      echo "ERROR: the Azure DevOps PAT has EXPIRED — renew it and re-export it." >&2
    elif [[ "$body_lc" == *"access denied"* || "$body_lc" == *"tf400813"* ]]; then
      echo "ERROR: Azure DevOps rejected the PAT (access denied)." >&2
    else
      echo "ERROR: API call failed: $1" >&2
      printf '%s\n' "$body" | head -c 400 >&2
    fi
    return 22
  fi
  printf '%s' "$body"
}

# ---- 1. discover the ticket's PRs project-wide ------------------------------
ALLOW_JSON=$(printf '%s' "$REPO_ALLOWLIST" | jq -R -s 'split("\n") | map(select(length > 0))')

echo "Ticket(s)   : ${TICKET}" >&2
echo "Release ref : ${RELEASE_REF}" >&2
echo "Fetching PRs from ${ORG}/${PROJECT} ..." >&2

RAW=$(mktemp)          # matched PRs: id \t title \t repo \t status \t isDraft \t source \t target
trap 'rm -f "$RAW"' EXIT

skip=0
while :; do
  PRS_JSON=$(api_get "${BASE}/pullRequests?searchCriteria.status=all&\$top=${PAGE_SIZE}&\$skip=${skip}&api-version=${API}")
  n=$(printf '%s' "$PRS_JSON" | jq '.value | length')
  [ "$n" -eq 0 ] && break

  printf '%s' "$PRS_JSON" \
    | jq -r --argjson allow "$ALLOW_JSON" --arg rf "$REPO_FILTER_LC" '
        .value[]
        | select(.repository.name as $n | $allow | index($n))
        | select($rf == "" or (.repository.name | ascii_downcase | contains($rf)))
        | [(.pullRequestId|tostring), .title, .repository.name, .status,
           (.isDraft|tostring), .sourceRefName, .targetRefName] | @tsv' \
    >> "$RAW"

  [ "$n" -lt "$PAGE_SIZE" ] && break
  skip=$((skip + PAGE_SIZE))
done

# Keep only PRs whose extracted ticket matches the filter.
MATCH=$(mktemp); trap 'rm -f "$RAW" "$MATCH"' EXIT
while IFS=$'\t' read -r PR_ID TITLE REPO STATUS ISDRAFT SRC TGT; do
  [ -z "$PR_ID" ] && continue
  ticket=$(printf '%s' "$TITLE" | grep -oE "$TICKET_RE" | head -n1 || true)
  [ -z "$ticket" ] && ticket=$(printf '%s' "$SRC" | grep -oE "$TICKET_RE" | head -n1 || true)
  keep=0
  [ -n "$TICKET_IDS" ] && printf '%s' "$TICKET_IDS" | grep -qxF "$ticket" && keep=1
  [ "$keep" -eq 0 ] && [ -n "$TICKET_NUMS" ] && printf '%s' "$TICKET_NUMS" | grep -qxF "${ticket##*-}" && keep=1
  [ "$keep" -eq 1 ] || continue
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ticket" "$PR_ID" "$TITLE" "$REPO" "$STATUS" "$ISDRAFT" "${SRC#refs/heads/}" >> "$MATCH"
done < "$RAW"

if [ ! -s "$MATCH" ]; then
  echo >&2
  echo "No PR found for ${TICKET} in the allow-listed repos." >&2
  exit 0
fi

NB=$(wc -l < "$MATCH" | tr -d ' ')
echo "Found ${NB} PR(s). Resolving merge commits and checking git history ..." >&2

# ---- 2. per repo: clone (cached) + resolve release ref ----------------------
mkdir -p "$CACHE"

# repo -> local bare dir (populated lazily). Also a per-repo "release ref present?"
declare -A REPO_DIR
declare -A REPO_REF          # resolved release ref name inside the clone ("" = absent)

ensure_repo() {
  local repo="$1"
  local dir="$CACHE/${repo}.git"
  REPO_DIR["$repo"]="$dir"
  if [ -d "$dir" ] && [ "$REFRESH" -eq 0 ]; then
    git "${GIT_AUTH[@]}" -C "$dir" fetch --quiet --prune --tags origin '+refs/heads/*:refs/heads/*' 2>/dev/null || true
  elif [ -d "$dir" ]; then
    git "${GIT_AUTH[@]}" -C "$dir" fetch --quiet --prune --tags origin '+refs/heads/*:refs/heads/*' 2>/dev/null || true
  else
    echo "  cloning ${repo} (commit graph only) ..." >&2
    if ! git "${GIT_AUTH[@]}" clone --bare --filter=blob:none --quiet \
           "${REPO_BASE}/${repo}" "$dir" 2>/dev/null; then
      # Fallback for servers that reject partial-clone filters.
      rm -rf "$dir"
      git "${GIT_AUTH[@]}" clone --bare --quiet "${REPO_BASE}/${repo}" "$dir" 2>/dev/null \
        || { echo "  ERROR: clone failed for ${repo}" >&2; REPO_DIR["$repo"]=""; return 1; }
    fi
  fi
  # Resolve the release ref: try as branch, then tag, then as-is.
  local r="" c
  for cand in "refs/heads/${RELEASE_REF}" "refs/tags/${RELEASE_REF}" "${RELEASE_REF}"; do
    if c=$(git -C "$dir" rev-parse --verify --quiet "${cand}^{commit}"); then r="$cand"; break; fi
  done
  REPO_REF["$repo"]="$r"
}

# ---- 3. evaluate each PR ----------------------------------------------------
# columns for the rendered table
RESULT=$(mktemp); trap 'rm -f "$RAW" "$MATCH" "$RESULT"' EXIT

# Binary verdict: is the PR in ${RELEASE_REF} or not.
in_count=0; notin_count=0

while IFS=$'\t' read -r TCK PR_ID TITLE REPO STATUS ISDRAFT SRC; do
  [ -z "$PR_ID" ] && continue

  verdict="NOT IN"; detail=""; mc_short="-"

  if [ "$STATUS" != "completed" ]; then
    if [ "$ISDRAFT" = "true" ]; then st="draft"; else st="$STATUS"; fi
    detail="not merged (PR is ${st})"
  else
    # merge commit from PR detail
    PR_JSON=$(api_get "${BASE}/pullRequests/${PR_ID}?api-version=${API}" || true)
    MC=$(printf '%s' "$PR_JSON" | jq -r '.lastMergeCommit.commitId // empty')
    TGT=$(printf '%s' "$PR_JSON" | jq -r '.targetRefName // empty' | sed 's#^refs/heads/##')

    if ! ensure_repo "$REPO" || [ -z "${REPO_DIR[$REPO]}" ]; then
      detail="⚠ cannot verify: repo clone unavailable"
    else
      dir="${REPO_DIR[$REPO]}"; ref="${REPO_REF[$REPO]}"
      [ -n "$MC" ] && mc_short="${MC:0:9}"

      if [ -z "$ref" ]; then
        detail="⚠ cannot verify: '${RELEASE_REF}' absent from ${REPO}"
      else
        anc=0; byid=0
        # signal 1: merge commit is an ancestor of the release ref
        if [ -n "$MC" ] && git -C "$dir" rev-parse --verify --quiet "${MC}^{commit}" >/dev/null; then
          if git -C "$dir" merge-base --is-ancestor "$MC" "$ref" 2>/dev/null; then anc=1; fi
        fi
        # signal 2: a commit reachable from the release carries "Merged PR <id>:"
        if git -C "$dir" log "$ref" --grep="Merged PR ${PR_ID}:" --fixed-strings \
             --format='%H' -n1 2>/dev/null | grep -q .; then byid=1; fi

        if [ "$anc" -eq 1 ] || [ "$byid" -eq 1 ]; then
          verdict="IN"
          sig=(); [ "$anc" -eq 1 ] && sig+=("ancestry"); [ "$byid" -eq 1 ] && sig+=("PR-id")
          detail="via ${sig[*]}"
        else
          detail="merged to ${TGT:-?}, not in ${RELEASE_REF}"
        fi
      fi
    fi
  fi

  [ "$verdict" = "IN" ] && in_count=$((in_count + 1)) || notin_count=$((notin_count + 1))

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$TCK" "$PR_ID" "$REPO" "$STATUS" "$mc_short" "$verdict" "$detail" >> "$RESULT"
done < "$MATCH"

# ---- 4. render report -------------------------------------------------------
icon() { [ "$1" = "IN" ] && printf '✅' || printf '❌'; }

echo
echo "================================================================================"
echo " In release ${RELEASE_REF}?"
echo " Ticket(s): ${TICKET}      (${ORG}/${PROJECT})"
echo "================================================================================"

for t in $(cut -f1 "$RESULT" | sort -u); do
  echo
  echo "### ${t}"
  while IFS=$'\t' read -r TCK PR_ID REPO STATUS MC VERDICT DETAIL; do
    [ "$TCK" = "$t" ] || continue
    printf '  %s  #%-6s %-32s %-9s %-7s %s\n' \
      "$(icon "$VERDICT")" "$PR_ID" "$REPO" "$MC" "$VERDICT" "$DETAIL"
  done < "$RESULT"
done

echo
echo "--------------------------------------------------------------------------------"
echo " Summary: ✅ ${in_count} in ${RELEASE_REF} | ❌ ${notin_count} not in it"
echo "--------------------------------------------------------------------------------"
echo " ✅ IN  = the PR's change is present in ${RELEASE_REF} (ancestry = exact merge"
echo "          inclusion; PR-id = release carries the 'Merged PR <id>:' commit,"
echo "          which also catches cherry-picks)."
echo " ❌ NOT IN = not merged, merged to another branch, or (⚠) the release ref does"
echo "          not exist in that repo so inclusion can't be confirmed."
