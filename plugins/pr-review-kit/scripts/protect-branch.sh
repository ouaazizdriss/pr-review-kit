#!/usr/bin/env bash
#
# protect-branch.sh
#
# Applies a standard set of Azure DevOps branch policies to a given branch
# (default: prod) across every repository in the allow-list.
#
# DRY-RUN BY DEFAULT: without --apply, only GET calls are made and the planned
# changes are printed. Nothing is modified until you pass --apply.
#
# Idempotent: an existing policy of the same type on the same repo+branch is
# UPDATED (PUT) rather than duplicated, and left untouched when already correct.
#
# Requirements: bash, curl, jq, AZURE_DEVOPS_PAT exported.
# The PAT needs "Code (read & write)" — policy writes are refused otherwise.
#
# Usage:
#   ./protect-branch.sh                       # dry-run on prod, all repos
#   ./protect-branch.sh --apply               # actually write the policies
#   ./protect-branch.sh -b release/42         # another branch
#   ./protect-branch.sh -p portal             # only repos matching "portal"
#   ./protect-branch.sh -m 1 --no-workitem    # 1 approver, drop WI linking
#   ./protect-branch.sh --apply --csv out.csv # write an audit trail
#
set -euo pipefail

. "$(dirname "$0")/lib/common.sh"
prr_load --no-auth
ORG="$ADO_ORG"
PROJECT="$ADO_PROJECT"
API="${ADO_API_VERSION:-7.0}"
GIT_BASE="https://dev.azure.com/${ORG}/${PROJECT}/_apis/git"
POLICY_BASE="https://dev.azure.com/${ORG}/${PROJECT}/_apis/policy"
ALLOWLIST="$REPO_ALLOWLIST_FILE"

# --- tunables ----------------------------------------------------------------
BRANCH="prod"
MIN_REVIEWERS=2
APPLY=0
REPO_FILTER=""
CSV=""
WANT_REVIEWERS=1
WANT_COMMENTS=1
WANT_WORKITEM=1
WANT_MERGE=1
WORKITEM_BLOCKING=true

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    -b|--branch)   BRANCH="$2"; shift 2 ;;
    -m|--min)      MIN_REVIEWERS="$2"; shift 2 ;;
    -p|--repo)     REPO_FILTER="$2"; shift 2 ;;
    --csv)         CSV="$2"; shift 2 ;;
    --apply)       APPLY=1; shift ;;
    --no-reviewers)  WANT_REVIEWERS=0; shift ;;
    --no-comments)   WANT_COMMENTS=0; shift ;;
    --no-workitem)   WANT_WORKITEM=0; shift ;;
    --no-merge)      WANT_MERGE=0; shift ;;
    --workitem-advisory) WORKITEM_BLOCKING=false; shift ;;
    -h|--help)     usage ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

: "${AZURE_DEVOPS_PAT:?AZURE_DEVOPS_PAT must be exported}"
command -v jq   >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
[ -f "$ALLOWLIST" ] || { echo "allow-list not found: $ALLOWLIST" >&2; exit 1; }

AUTH=$(printf ":%s" "$AZURE_DEVOPS_PAT" | base64 -w0)
REF="refs/heads/${BRANCH}"

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
C_OK=$'\033[32m'; C_NEW=$'\033[36m'; C_UPD=$'\033[33m'; C_SKIP=$'\033[35m'; C_ERR=$'\033[31m'
[ -t 1 ] || { C_RESET=; C_BOLD=; C_DIM=; C_OK=; C_NEW=; C_UPD=; C_SKIP=; C_ERR=; }

api_get() { curl -sS --fail-with-body -H "Authorization: Basic ${AUTH}" "$1"; }
api_send() { # method url body
  curl -sS --fail-with-body -X "$1" \
       -H "Authorization: Basic ${AUTH}" \
       -H "Content-Type: application/json" \
       -d "$3" "$2"
}

# --- resolve policy type ids from the live org (fallback to known GUIDs) ------
TYPES_JSON=$(api_get "${POLICY_BASE}/types?api-version=${API}")
type_id() { # display-name fallback-guid
  local id
  id=$(jq -r --arg n "$1" '[.value[] | select(.displayName==$n) | .id][0] // empty' <<<"$TYPES_JSON")
  echo "${id:-$2}"
}
T_REVIEWERS=$(type_id "Minimum number of reviewers" fa4e907d-c16b-4a4c-9dfa-4906e5d171dd)
T_COMMENTS=$(type_id  "Comment requirements"        c6a1889d-b943-4856-b76f-9e46bb6b0df2)
T_WORKITEM=$(type_id  "Work item linking"           40e92b44-2fe1-4dd6-b3d8-74a9c21d0c6e)
T_MERGE=$(type_id     "Require a merge strategy"    fa4e907d-c16b-4a4c-9dfa-4916e5d171ab)

# --- desired policy bodies ---------------------------------------------------
# Each builder prints the full policy configuration JSON for one repo.
desired_policies() { # repoId
  local rid="$1" scope
  scope=$(jq -n --arg r "$rid" --arg ref "$REF" \
            '[{repositoryId:$r, refName:$ref, matchKind:"Exact"}]')

  if [ "$WANT_REVIEWERS" -eq 1 ]; then
    jq -c -n --arg t "$T_REVIEWERS" --argjson s "$scope" --argjson n "$MIN_REVIEWERS" '{
      isEnabled:true, isBlocking:true, type:{id:$t},
      settings:{
        minimumApproverCount:$n,
        creatorVoteCounts:false,
        allowDownvotes:false,
        resetOnSourcePush:true,
        requireVoteOnLastIteration:true,
        resetRejectionsOnSourcePush:true,
        blockLastPusherVote:true,
        scope:$s }}'
  fi
  if [ "$WANT_COMMENTS" -eq 1 ]; then
    jq -c -n --arg t "$T_COMMENTS" --argjson s "$scope" '{
      isEnabled:true, isBlocking:true, type:{id:$t}, settings:{scope:$s}}'
  fi
  if [ "$WANT_WORKITEM" -eq 1 ]; then
    jq -c -n --arg t "$T_WORKITEM" --argjson s "$scope" --argjson b "$WORKITEM_BLOCKING" '{
      isEnabled:true, isBlocking:$b, type:{id:$t}, settings:{scope:$s}}'
  fi
  if [ "$WANT_MERGE" -eq 1 ]; then
    jq -c -n --arg t "$T_MERGE" --argjson s "$scope" '{
      isEnabled:true, isBlocking:true, type:{id:$t},
      settings:{
        allowSquash:true,
        allowNoFastForward:false,
        allowRebase:false,
        allowRebaseMerge:false,
        scope:$s }}'
  fi
}

type_label() {
  case "$1" in
    "$T_REVIEWERS") echo "min-reviewers(${MIN_REVIEWERS})" ;;
    "$T_COMMENTS")  echo "comments-resolved" ;;
    "$T_WORKITEM")  echo "work-item-linking" ;;
    "$T_MERGE")     echo "merge-strategy(squash)" ;;
    *)              echo "$1" ;;
  esac
}

# Does the existing config already satisfy the desired one?
policy_matches() { # existing desired
  jq -e -n --argjson e "$1" --argjson d "$2" '
    ($d.settings | del(.scope)) as $ds
    | ($e.isEnabled  == $d.isEnabled)
      and ($e.isBlocking == $d.isBlocking)
      and (all($ds | keys_unsorted[]; . as $k | $e.settings[$k] == $ds[$k]))
  ' >/dev/null
}

# --- all policy configurations in the project, once, then filtered locally ----
fetch_all_configs() {
  local url token hdr body tmp
  tmp=$(mktemp); : >"$tmp"
  url="${POLICY_BASE}/configurations?api-version=${API}&\$top=1000"
  while :; do
    hdr=$(mktemp)
    body=$(curl -sS --fail-with-body -D "$hdr" -H "Authorization: Basic ${AUTH}" "$url")
    jq -c '.value[]' <<<"$body" >>"$tmp"
    token=$(tr -d '\r' <"$hdr" | awk -F': ' 'tolower($1)=="x-ms-continuationtoken"{print $2}')
    rm -f "$hdr"
    [ -n "$token" ] || break
    url="${POLICY_BASE}/configurations?api-version=${API}&\$top=1000&continuationToken=${token}"
  done
  jq -s '.' "$tmp"; rm -f "$tmp"
}

echo "${C_BOLD}Branch protection — ${ORG}/${PROJECT}${C_RESET}"
echo "${C_DIM}branch=${REF}  min-reviewers=${MIN_REVIEWERS}  repos=$(grep -c . "$ALLOWLIST")  filter=${REPO_FILTER:-none}${C_RESET}"
if [ "$APPLY" -eq 1 ]; then
  echo "${C_ERR}${C_BOLD}MODE: APPLY — policies will be written${C_RESET}"
else
  echo "${C_OK}MODE: DRY-RUN — read-only, nothing will be modified${C_RESET}"
fi
echo

ALL_CONFIGS=$(fetch_all_configs)

n_repos=0; n_nobranch=0; n_create=0; n_update=0; n_ok=0; n_err=0
[ -n "$CSV" ] && echo "repo,branch,policy,action,detail" > "$CSV"

while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  case "$repo" in \#*) continue ;; esac
  if [ -n "$REPO_FILTER" ]; then
    printf '%s' "$repo" | grep -qi -- "$REPO_FILTER" || continue
  fi
  n_repos=$((n_repos+1))

  if ! repo_json=$(api_get "${GIT_BASE}/repositories/${repo}?api-version=${API}" 2>/dev/null); then
    echo "${C_ERR}✗ ${repo}${C_RESET}  repo not found / no access"
    n_err=$((n_err+1)); [ -n "$CSV" ] && echo "$repo,$BRANCH,-,error,repo-not-found" >>"$CSV"
    continue
  fi
  rid=$(jq -r '.id' <<<"$repo_json")

  refs=$(api_get "${GIT_BASE}/repositories/${rid}/refs?filter=heads/${BRANCH}&api-version=${API}")
  if [ "$(jq -r --arg r "$REF" '[.value[]?|select(.name==$r)]|length' <<<"$refs")" -eq 0 ]; then
    echo "${C_SKIP}⊘ ${repo}${C_RESET}  no ${BRANCH} branch — skipped"
    n_nobranch=$((n_nobranch+1)); [ -n "$CSV" ] && echo "$repo,$BRANCH,-,skipped,no-such-branch" >>"$CSV"
    continue
  fi

  echo "${C_BOLD}${repo}${C_RESET}"
  while IFS= read -r want; do
    [ -n "$want" ] || continue
    tid=$(jq -r '.type.id' <<<"$want")
    label=$(type_label "$tid")

    existing=$(jq -c --arg t "$tid" --arg r "$rid" --arg ref "$REF" \
      '[.[] | select(.type.id==$t)
            | select(.settings.scope // [] | any(.repositoryId==$r and .refName==$ref))][0] // empty' \
      <<<"$ALL_CONFIGS")

    if [ -n "$existing" ]; then
      cfg_id=$(jq -r '.id' <<<"$existing")
      if policy_matches "$existing" "$want"; then
        echo "  ${C_OK}= ${label}${C_RESET} ${C_DIM}already compliant (#${cfg_id})${C_RESET}"
        n_ok=$((n_ok+1)); [ -n "$CSV" ] && echo "$repo,$BRANCH,$label,unchanged,#$cfg_id" >>"$CSV"
        continue
      fi
      echo "  ${C_UPD}~ ${label}${C_RESET} update existing #${cfg_id}"
      n_update=$((n_update+1)); [ -n "$CSV" ] && echo "$repo,$BRANCH,$label,update,#$cfg_id" >>"$CSV"
      if [ "$APPLY" -eq 1 ]; then
        api_send PUT "${POLICY_BASE}/configurations/${cfg_id}?api-version=${API}" "$want" >/dev/null \
          || { echo "    ${C_ERR}PUT failed${C_RESET}"; n_err=$((n_err+1)); }
      fi
    else
      echo "  ${C_NEW}+ ${label}${C_RESET} create"
      n_create=$((n_create+1)); [ -n "$CSV" ] && echo "$repo,$BRANCH,$label,create," >>"$CSV"
      if [ "$APPLY" -eq 1 ]; then
        api_send POST "${POLICY_BASE}/configurations?api-version=${API}" "$want" >/dev/null \
          || { echo "    ${C_ERR}POST failed${C_RESET}"; n_err=$((n_err+1)); }
      fi
    fi
  done < <(desired_policies "$rid")
done < "$ALLOWLIST"

echo
echo "${C_BOLD}Summary${C_RESET}  repos=${n_repos}  ${C_SKIP}no-branch=${n_nobranch}${C_RESET}  ${C_NEW}create=${n_create}${C_RESET}  ${C_UPD}update=${n_update}${C_RESET}  ${C_OK}unchanged=${n_ok}${C_RESET}  ${C_ERR}errors=${n_err}${C_RESET}"
[ "$APPLY" -eq 0 ] && echo "${C_DIM}dry-run — re-run with --apply to write these ${n_create} creates / ${n_update} updates${C_RESET}"
[ -n "$CSV" ] && echo "${C_DIM}audit trail: ${CSV}${C_RESET}"
exit 0
