#!/usr/bin/env bash
# scan.sh — enumerate the active PRs of the allow-listed repositories and write one
# state line per PR to $STATE_DIR/state.jsonl (read by filter.sh). Read-only (GET only).
#
# Per PR it records: metadata, my live vote and required flag, team assignment,
# the current source tip and the date that tip was FIRST pushed (a new iteration
# created only because the target branch moved is not a new push), my last marked
# comment, my last review (marked, or an unmarked comment of 400+ characters — re-reviews
# posted as replies before every comment carried the marker), short unmarked comments
# under my identity after my last marked one (owner decisions), human comments after my last comment, and my last vote from the
# votes ledger (state/votes.jsonl, written by post.sh) to detect vote resets.
set -uo pipefail
. "$(dirname "$0")/lib/common.sh"
prr_load
ME=$(prr_reviewer_id)
MARKERS=$(prr_markers_json)

exec 9>"$STATE_DIR/.scan.lock"
flock -w 300 9 || prr_die "another scan is running"

[ -f "$REPO_ALLOWLIST_FILE" ] || prr_die "allowlist not found: $REPO_ALLOWLIST_FILE"
ALLOW=$(grep -vE '^\s*(#|$)' "$REPO_ALLOWLIST_FILE" | sed 's/\s*$//' | jq -R . | jq -sc .)
EXCLUDED=$(printf '%s\n' ${EXCLUDED_PRS:-} | grep . | jq -R 'tonumber? // empty' | jq -sc .)
LEDGER="$STATE_DIR/votes.jsonl"; [ -f "$LEDGER" ] || : > "$LEDGER"
LASTCAST=$(jq -sc 'group_by(.id) | map(sort_by(.date) | last) | map({key:(.id|tostring), value:.}) | from_entries' "$LEDGER" 2>/dev/null || echo '{}')

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
: > "$TMP/prs.jsonl"
skip=0
while :; do
  r=$(prr_get_list "$ADO_BASE/pullrequests?searchCriteria.status=active&\$top=100&\$skip=$skip&api-version=$ADO_API_VERSION") \
    || { prr_warn "PR list incomplete"; break; }
  n=$(echo "$r" | jq '.value|length')
  echo "$r" | jq -c '.value[]' >> "$TMP/prs.jsonl"
  [ "$n" -lt 100 ] && break
  skip=$((skip+100))
done
jq -c --argjson a "$ALLOW" 'select(.repository.name as $n | $a | index($n))' "$TMP/prs.jsonl" > "$STATE_DIR/prs.jsonl"
echo "scan: $(wc -l < "$TMP/prs.jsonl") active PRs, $(wc -l < "$STATE_DIR/prs.jsonl") in scope" >&2

: > "$TMP/state.jsonl"
while read -r pr; do
  id=$(echo "$pr" | jq -r .pullRequestId); repo=$(echo "$pr" | jq -r .repository.name)
  prr_get_list "$ADO_REPOS_BASE/$repo/pullRequests/$id/threads?api-version=$ADO_API_VERSION" > "$TMP/th.json" || { prr_warn "skip $id (threads unreadable)"; continue; }
  prr_get_list "$ADO_REPOS_BASE/$repo/pullRequests/$id/iterations?api-version=$ADO_API_VERSION" > "$TMP/it.json" || { prr_warn "skip $id (iterations unreadable)"; continue; }
  echo "$pr" > "$TMP/pr.json"
  jq -nc --slurpfile pr0 "$TMP/pr.json" --slurpfile th0 "$TMP/th.json" --slurpfile it0 "$TMP/it.json" \
     --arg me "$ME" --arg team "${TEAM_GROUP_ID:-}" --argjson markers "$MARKERS" \
     --argjson excluded "$EXCLUDED" --argjson lastcast "$LASTCAST" --arg ticketre "$TICKET_KEY_REGEX" '
    $pr0[0] as $pr | $th0[0] as $th | $it0[0] as $it | ($th.value // []) as $t
    | def marked: . as $c | any($markers[]; . as $m | $c | contains($m));
    [ $t[] | .id as $tid | .status as $tst | (.comments // [])[] | select(.commentType != "system")
      | {tid:$tid, tstatus:$tst, a:.author.id, an:.author.displayName, d:.publishedDate,
         m:((.content // "") | marked), parent:.parentCommentId,
         c:((.content // "")[0:300]), len:((.content // "") | length)} ] as $cs
    | ([ $cs[] | select(.a == $me) ] | sort_by(.d) | last) as $mine
    | ([ $cs[] | select(.a == $me and .m) ] | sort_by(.d) | last) as $mineM
    | ([ $cs[] | select(.a == $me and (.m or .len >= 400)) ] | sort_by(.d) | last) as $mineR
    | ($it.value // []) as $its | ($its | last) as $li
    | ($li.sourceRefCommit.commitId) as $tip
    | ([ $its[] | select(.sourceRefCommit.commitId == $tip) | .createdDate ] | min) as $firstPush
    | ($lastcast[($pr.pullRequestId|tostring)] // null) as $lc
    | ((($pr.title // "") + " " + ($pr.sourceRefName // "")) | [match($ticketre; "g").string] | first) as $ticket
    | {id:$pr.pullRequestId, repo:$pr.repository.name, title:$pr.title, ticket:$ticket,
       src:$pr.sourceRefName, tgt:$pr.targetRefName, draft:$pr.isDraft,
       author:$pr.createdBy.displayName, authorId:$pr.createdBy.id, selfAuthored:($pr.createdBy.id == $me),
       created:$pr.creationDate, merge:$pr.mergeStatus,
       excluded:(($excluded | index($pr.pullRequestId)) != null),
       myVote:([ ($pr.reviewers // [])[] | select(.id == $me) | .vote ] | first),
       meReq:([ ($pr.reviewers // [])[] | select(.id == $me) | .isRequired ] | first),
       team:(($team != "") and ([ ($pr.reviewers // [])[] | select(.id == $team) ] | length > 0)),
       iters:($its | length), tip:$tip, lastPush:$firstPush, lastIter:$li.createdDate,
       myLast:$mine.d, myLastMarked:$mineM.d, myLastReview:$mineR.d, myThread:$mineM.tid, lastCast:$lc,
       ownerManual:[ $cs[] | select(.a == $me and (.m | not) and .len < 400 and ($mineM.d == null or .d > $mineM.d)) | {d, tid, c} ],
       humanAfter:[ $cs[] | select(.a != $me and ($mine.d == null or .d > $mine.d)) | {an, d, tid, parent, c} ] }' >> "$TMP/state.jsonl"
done < "$STATE_DIR/prs.jsonl"
mv "$TMP/state.jsonl" "$STATE_DIR/state.jsonl"
echo "scan: state written to $STATE_DIR/state.jsonl ($(wc -l < "$STATE_DIR/state.jsonl") PRs)" >&2
