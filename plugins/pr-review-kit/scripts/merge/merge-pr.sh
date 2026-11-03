#!/usr/bin/env bash
# merge-pr.sh <repo> <prId> [--dry-run] [--expect-tip SHA] — squash-merge an approved PR.
# Prints "OK <squashCommit>[ (bypass)]" or "FAIL <reason>"; exit 0 on OK, 1 on FAIL.
#
# Preconditions checked live: PR active, not Draft, my vote is +10, merge evaluation
# succeeded, and the source tip is the commit that was approved — the tip recorded with my
# last +10 in $STATE_DIR/votes.jsonl, or the SHA given with --expect-tip. A push after the
# approval therefore blocks the merge until the PR is reviewed again.
# Only MY active threads are resolved; an active thread opened by anyone else blocks the
# merge. When the branch policy demands more approvers, the policy is bypassed only if
# MERGE_ALLOW_BYPASS=true.
set -u
. "$(dirname "$0")/lib.sh"
USAGE="usage: merge-pr.sh <repo> <prId> [--dry-run] [--expect-tip SHA]"
r="${1:?$USAGE}"; id="${2:?$USAGE}"; shift 2
DRY=0; EXPECT_TIP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --expect-tip) EXPECT_TIP="${2:?$USAGE}"; shift 2 ;;
    *) echo "FAIL unknown argument $1 ($USAGE)"; exit 1 ;;
  esac
done
B="$ADO_REPOS_BASE/$r/pullRequests/$id"
get() { ado_get "$B?$V"; }

j=$(get)
st=$(jq -r '.status // empty' <<<"$j"); dr=$(jq -r '.isDraft // false' <<<"$j")
[ -n "$st" ] || { echo "FAIL PR not found"; exit 1; }
if [ "$st" = completed ]; then echo "OK $(jq -r .lastMergeCommit.commitId <<<"$j") (already)"; exit 0; fi
[ "$st" != active ] && { echo "FAIL status=$st"; exit 1; }
[ "$dr" = true ] && { echo "FAIL draft"; exit 1; }
[ "$(jq -r --arg me "$ME" '[.reviewers[] | select(.id == $me) | .vote][0]' <<<"$j")" = 10 ] || { echo "FAIL my vote is no longer +10"; exit 1; }

# the approved commit: --expect-tip, else the tip recorded with my last +10 on this PR
approved="$EXPECT_TIP"
if [ -z "$approved" ] && [ -f "$STATE_DIR/votes.jsonl" ]; then
  approved=$(jq -r --arg r "$r" --argjson id "$id" 'select(.repo == $r and .id == $id)' "$STATE_DIR/votes.jsonl" 2>/dev/null \
    | jq -rs 'last // {} | if .vote == 10 then .tip // "" else "" end')
fi
[ -n "$approved" ] || { echo "FAIL no approved tip recorded for this PR (vote not cast through post.sh) — pass --expect-tip <reviewed commit>"; exit 1; }
live=$(jq -r .lastMergeSourceCommit.commitId <<<"$j")
[ "$live" = "$approved" ] || { echo "FAIL source tip moved since the approval: approved ${approved:0:10}, live ${live:0:10} — review the new commits first"; exit 1; }

ms=$(jq -r .mergeStatus <<<"$j")
for _ in $(seq 1 10); do [ "$ms" = queued ] || break; sleep 5; j=$(get); # the approved commit: --expect-tip, else the tip recorded with my last +10 on this PR
approved="$EXPECT_TIP"
if [ -z "$approved" ] && [ -f "$STATE_DIR/votes.jsonl" ]; then
  approved=$(jq -r --arg r "$r" --argjson id "$id" 'select(.repo == $r and .id == $id)' "$STATE_DIR/votes.jsonl" 2>/dev/null \
    | jq -rs 'last // {} | if .vote == 10 then .tip // "" else "" end')
fi
[ -n "$approved" ] || { echo "FAIL no approved tip recorded for this PR (vote not cast through post.sh) — pass --expect-tip <reviewed commit>"; exit 1; }
live=$(jq -r .lastMergeSourceCommit.commitId <<<"$j")
[ "$live" = "$approved" ] || { echo "FAIL source tip moved since the approval: approved ${approved:0:10}, live ${live:0:10} — review the new commits first"; exit 1; }

ms=$(jq -r .mergeStatus <<<"$j"); done
[ "$ms" = succeeded ] || { echo "FAIL mergeStatus=$ms"; exit 1; }
if [ "$DRY" = 1 ]; then echo "OK dry-run (would squash-merge $(jq -r .lastMergeSourceCommit.commitId <<<"$j" | cut -c1-10))"; exit 0; fi

threads=$(ado_get "$B/threads?$V")
others=$(jq -r --arg me "$ME" '[.value[] | select(.isDeleted != true and (.status == "active" or .status == "pending")
          and .comments[0].commentType != "system" and .comments[0].author.id != $me) | .id] | join(",")' <<<"$threads")
[ -z "$others" ] || { echo "FAIL active thread(s) from other reviewers: $others — they must be resolved by their authors"; exit 1; }
for t in $(jq -r --arg me "$ME" '.value[] | select(.isDeleted != true and (.status == "active" or .status == "pending")
          and .comments[0].commentType != "system" and .comments[0].author.id == $me) | .id' <<<"$threads"); do
  ado_write PATCH "$B/threads/$t?$V" '{"status":"fixed"}' >/dev/null
done

# tip re-read once more just before completing: a push during the checks must not slip in
j=$(get); tip=$(jq -r .lastMergeSourceCommit.commitId <<<"$j"); title=$(jq -r .title <<<"$j")
[ "$tip" = "$approved" ] || { echo "FAIL source tip moved during the merge checks (${tip:0:10}) — review the new commits first"; exit 1; }
complete() { # $1 = bypass true|false
  local body
  body=$(jq -n --arg c "$tip" --arg m "Merged PR $id: $title" --argjson bp "$1" \
    --arg why "${MERGE_BYPASS_REASON:-Approved by the reviewer; additional approver policy bypassed at the reviewer request}" \
    --argjson del "${MERGE_DELETE_SOURCE_BRANCH:-false}" \
    '{status:"completed", lastMergeSourceCommit:{commitId:$c},
      completionOptions:({mergeStrategy:"squash", deleteSourceBranch:$del, mergeCommitMessage:$m, transitionWorkItems:false}
        + (if $bp then {bypassPolicy:true, bypassReason:$why} else {} end))}')
  ado_write PATCH "$B?$V" "$body"
}
res=$(complete false); bypass=""
if jq -e '.message // "" | test("override to bypass policies")' <<<"$res" >/dev/null; then
  [ "${MERGE_ALLOW_BYPASS:-false}" = true ] || { echo "FAIL branch policy requires more approvals (set MERGE_ALLOW_BYPASS=true to bypass)"; exit 1; }
  res=$(complete true); bypass=" (bypass)"
fi
jq -e '.status' <<<"$res" >/dev/null || { echo "FAIL $(jq -r '.message // "unknown error"' <<<"$res")"; exit 1; }

for _ in $(seq 1 12); do sleep 5; j=$(get); st=$(jq -r .status <<<"$j"); [ "$st" = completed ] && break; done
if [ "$st" = completed ]; then echo "OK $(jq -r .lastMergeCommit.commitId <<<"$j")$bypass"
else echo "FAIL not completed (status=$st mergeStatus=$(jq -r .mergeStatus <<<"$j"))"; exit 1; fi
