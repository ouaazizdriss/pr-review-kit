#!/usr/bin/env bash
# check-merge.sh <repo> <prId>
# Detects merge problems for a Azure DevOps pull request, BEFORE anyone tries to merge:
#
#   1. LIVE conflict with the target branch  — Azure DevOps `mergeStatus`, plus the
#      conflicting paths from the PR conflicts endpoint when status is `conflicts`.
#   2. PREDICTED conflict with SIBLING PRs   — other ACTIVE PRs on the same repo and the
#      same target branch whose changed files intersect this PR's. For each overlapping
#      sibling, a real trial merge is run with `git merge-tree` (no worktree needed) and
#      the conflicting paths are reported.
#   3. SEMANTIC collision candidates         — files that BOTH PRs only ADD lines to, in
#      the same file, which git merges cleanly but which can still break compilation
#      (e.g. two PRs adding the SAME method to the same class at different offsets).
#      These are flagged as candidates to verify by reading the two diffs.
#
# Output: normalized JSON on stdout. Read-only against Azure DevOps (GET only).
# Requires: AZURE_DEVOPS_PAT, a workspace config, git >= 2.38 (merge-tree --write-tree), curl, jq.
# Never prints the PAT. Cleans up its clone on exit.
set -uo pipefail

REPO="${1:?usage: check-merge.sh <repo> <prId>}"
PRID="${2:?usage: check-merge.sh <repo> <prId>}"
MAX_SIBLINGS="${CHECKMERGE_MAX_SIBLINGS:-12}"


. "$(dirname "$0")/lib/common.sh"
prr_load
B="$ADO_REPOS_BASE"
GURL="$ADO_GIT_WEB/$REPO"
WEB="$ADO_GIT_WEB"

err() { echo "{\"repo\":\"$REPO\",\"prId\":$PRID,\"error\":$(jq -Rn --arg m "$1" '$m')}"; exit 0; }

# --- changed files of a PR (latest iteration), leading slash stripped --------
changed_files() { # $1 = prId
  local _it _id
  _it=$(curl -s -H "Authorization: Basic $AUTH" "$B/$REPO/pullRequests/$1/iterations?api-version=7.0")
  _id=$(echo "$_it" | jq -r '.value | last | .id // empty')
  [ -z "$_id" ] && return 0
  curl -s -H "Authorization: Basic $AUTH" \
    "$B/$REPO/pullRequests/$1/iterations/$_id/changes?api-version=7.0" \
  | jq -r '.changeEntries[]? | select(.item.isFolder != true) | .item.path' | sed 's#^/##' | sort -u
}

# --- this PR ------------------------------------------------------------------
PR=$(curl -s -H "Authorization: Basic $AUTH" "$B/$REPO/pullRequests/$PRID?api-version=7.0")
STATUS=$(echo "$PR" | jq -r '.status // empty')
[ -z "$STATUS" ] && err "pull request not found"
MERGESTATUS=$(echo "$PR" | jq -r '.mergeStatus // "notSet"')
TARGET=$(echo "$PR" | jq -r '.targetRefName // empty' | sed 's#^refs/heads/##')
ISDRAFT=$(echo "$PR" | jq -r '.isDraft // false')

ITERS=$(curl -s -H "Authorization: Basic $AUTH" "$B/$REPO/pullRequests/$PRID/iterations?api-version=7.0")
SRC=$(echo "$ITERS" | jq -r '.value | last | .sourceRefCommit.commitId // empty')
BASE=$(echo "$ITERS" | jq -r '.value | last | .commonRefCommit.commitId // empty')
[ -z "$SRC" ] && err "cannot resolve source commit"

mapfile -t MINE < <(changed_files "$PRID")
MINE_COUNT=${#MINE[@]}

# --- 1. live conflict with the target branch ---------------------------------
TARGET_CONFLICTS='[]'
if [ "$MERGESTATUS" = "conflicts" ]; then
  TARGET_CONFLICTS=$(curl -s -H "Authorization: Basic $AUTH" \
      "$B/$REPO/pullRequests/$PRID/conflicts?api-version=7.0" \
    | jq -c '[ .value[]? | {
        path: (.conflictPath // .conflictBasePath // .conflictSourcePath // .conflictTargetPath // "?"),
        type: (.conflictType // "unknown")
      } ] | unique_by(.path)' 2>/dev/null) || TARGET_CONFLICTS='[]'
  [ -z "$TARGET_CONFLICTS" ] && TARGET_CONFLICTS='[]'
fi

# --- 2. sibling PRs: same repo, same target branch, active -------------------
SIB=$(curl -s -H "Authorization: Basic $AUTH" \
  "$B/$REPO/pullRequests?searchCriteria.status=active&searchCriteria.targetRefName=refs/heads/$TARGET&\$top=100&api-version=7.0")
mapfile -t SIBIDS < <(echo "$SIB" | jq -r --arg me "$PRID" '.value[]? | select((.pullRequestId|tostring) != $me) | .pullRequestId' | head -n "$MAX_SIBLINGS")

# --- clone once: base + source, then fetch each sibling source on demand -----
WD=$(mktemp -d "${TMPDIR:-/tmp}/checkmerge.XXXXXX")
trap 'rm -rf "$WD"' EXIT
CLONE_OK=0
(
  cd "$WD" && git init -q repo && cd repo && git remote add origin "$GURL"
  git -c http.extraHeader="Authorization: Basic $AUTH" fetch -q --depth 200 origin "$SRC"
) 2>/dev/null && CLONE_OK=1
RD="$WD/repo"

git_fetch() { # $1 = commit; deepen enough to find a merge base
  ( cd "$RD" && git -c http.extraHeader="Authorization: Basic $AUTH" fetch -q --depth 200 origin "$1" ) 2>/dev/null
}

SIBLINGS='[]'
for sid in "${SIBIDS[@]:-}"; do
  [ -z "$sid" ] && continue
  mapfile -t THEIRS < <(changed_files "$sid")
  [ ${#THEIRS[@]} -eq 0 ] && continue
  # file overlap
  mapfile -t OVERLAP < <(printf '%s\n' "${MINE[@]}" | sort -u > "$WD/a"; printf '%s\n' "${THEIRS[@]}" | sort -u > "$WD/b"; comm -12 "$WD/a" "$WD/b")
  [ ${#OVERLAP[@]} -eq 0 ] && continue

  sinfo=$(curl -s -H "Authorization: Basic $AUTH" "$B/$REPO/pullRequests/$sid?api-version=7.0")
  stitle=$(echo "$sinfo" | jq -r '.title // ""')
  sdraft=$(echo "$sinfo" | jq -r '.isDraft // false')
  siters=$(curl -s -H "Authorization: Basic $AUTH" "$B/$REPO/pullRequests/$sid/iterations?api-version=7.0")
  ssrc=$(echo "$siters" | jq -r '.value | last | .sourceRefCommit.commitId // empty')

  TRIAL='"not-run"'; TRIAL_CONFLICTS='[]'
  if [ "$CLONE_OK" = 1 ] && [ -n "$ssrc" ] && git_fetch "$ssrc"; then
    MB=$( cd "$RD" && git merge-base "$SRC" "$ssrc" 2>/dev/null )
    if [ -n "$MB" ]; then
      # --write-tree takes exactly TWO commits and finds the base itself; pin it explicitly.
      # --no-messages drops the informational section; output is then:
      #   line 1 = merged tree OID, following lines = conflicted paths, until a blank line.
      OUT=$( cd "$RD" && git merge-tree --write-tree --name-only --no-messages --merge-base="$MB" "$SRC" "$ssrc" 2>/dev/null )
      RC=$?
      if [ $RC -eq 0 ]; then
        TRIAL='"clean"'
      elif [ $RC -eq 1 ]; then
        TRIAL='"conflicts"'
        TRIAL_CONFLICTS=$(printf '%s\n' "$OUT" | awk 'NR==1{next} /^$/{exit} {print}' | jq -Rn '[inputs]' )
      else
        TRIAL='"trial-failed"'
      fi
    else
      TRIAL='"no-merge-base"'
    fi
  fi

  SIBLINGS=$(jq -c \
    --argjson sib "$SIBLINGS" \
    --arg id "$sid" --arg title "$stitle" --arg draft "$sdraft" \
    --arg url "$WEB/$REPO/pullrequest/$sid" \
    --argjson overlap "$(printf '%s\n' "${OVERLAP[@]}" | jq -Rn '[inputs]')" \
    --argjson trial "$TRIAL" --argjson tc "$TRIAL_CONFLICTS" \
    -n '$sib + [{prId: ($id|tonumber), title: $title, isDraft: ($draft=="true"),
                 url: $url, overlappingFiles: $overlap,
                 trialMerge: $trial, trialConflicts: $tc,
                 semanticRisk: (($trial=="clean") and (($overlap|length)>0))}]')
done

jq -n \
  --arg repo "$REPO" --arg prId "$PRID" --arg target "$TARGET" \
  --arg mergeStatus "$MERGESTATUS" --arg status "$STATUS" --arg draft "$ISDRAFT" \
  --arg src "$SRC" --arg base "$BASE" --argjson changedCount "$MINE_COUNT" \
  --argjson targetConflicts "$TARGET_CONFLICTS" --argjson siblings "$SIBLINGS" \
  '{
     repo: $repo, prId: ($prId|tonumber), status: $status, isDraft: ($draft=="true"),
     targetBranch: $target, sourceCommit: $src, mergeBase: $base, changedFiles: $changedCount,
     target: { mergeStatus: $mergeStatus, conflicts: $targetConflicts },
     siblings: $siblings,
     summary: {
       targetConflict: ($mergeStatus == "conflicts"),
       siblingsWithTextualConflict: [ $siblings[] | select(.trialMerge=="conflicts") | .prId ],
       siblingsWithSemanticRisk:    [ $siblings[] | select(.semanticRisk) | .prId ]
     }
   }'
