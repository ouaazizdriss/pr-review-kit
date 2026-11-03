#!/usr/bin/env bash
# post.sh — the ONLY way the kit writes review comments and votes to Azure DevOps.
# Every guard of the review policy that can be checked mechanically lives here.
#
#   post.sh thread       <repo> <prId> <file>              [--expect-tip SHA]
#   post.sh reply        <repo> <prId> <threadId> <file>   [--expect-tip SHA] [--parent N]
#   post.sh vote         <repo> <prId> <10|5|0|-5>         [--expect-tip SHA]
#   post.sh add-required <repo> <prId>                     (required reviewer, vote 0)
#   post.sh reopen       <repo> <prId> <threadId>          (thread status back to active)
#
# Guards:
#   POST_MODE   dry-run → nothing leaves the machine, payloads go to $STATE_DIR/outbox/
#               comment → comments are posted, votes stay in the outbox
#               comment+vote → everything is posted
#   marker      the content is prefixed with PR_MARKER when missing
#   wording     refuses content that names an AI vendor or says the review is generated
#   tip         --expect-tip refuses to post when the PR source tip moved (exit 3); a +10
#               REQUIRES --expect-tip with the full 40-character SHA of the reviewed commit, and
#               the ledgers record that SHA (none if the tip moved during the vote)
#   status      abandoned PR → refused; completed PR → comments allowed (post-merge
#               feedback), votes refused (exit 5)
#   votes       never -10; Draft → only 0; no self-vote on your own PR (exit 6);
#               +5 only with POLICY_PROFILE=standard; always isRequired:true; the live
#               vote is read back and appended to $STATE_DIR/votes.jsonl and to the
#               protected ledger outside the workspace (prr_ledger_file)
# Output: one JSON line per action.
set -uo pipefail
. "$(dirname "$0")/lib/common.sh"
prr_load

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
KIND="${1:-}"; shift || true
[ -n "$KIND" ] || usage

EXPECT_TIP=""; PARENT=""; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --expect-tip) EXPECT_TIP="$2"; shift 2 ;;
    --parent)     PARENT="$2"; shift 2 ;;
    *)            ARGS+=("$1"); shift ;;
  esac
done
REPO="${ARGS[0]:-}"; PRID="${ARGS[1]:-}"
[ -n "$REPO" ] && [ -n "$PRID" ] || usage
ME=$(prr_reviewer_id)
B="$ADO_REPOS_BASE/$REPO/pullRequests/$PRID"
V="api-version=$ADO_API_VERSION"

fail() { jq -cn --arg k "$KIND" --arg m "$2" --argjson pr "$PRID" '{ok:false,kind:$k,pr:$pr,error:$m}'; exit "$1"; }

PR=$(prr_get "$B?$V") || fail 1 "cannot read the PR"
STATUS=$(echo "$PR" | jq -r '.status // empty'); DRAFT=$(echo "$PR" | jq -r '.isDraft // false')
AUTHOR_ID=$(echo "$PR" | jq -r '.createdBy.id // empty')
[ -n "$STATUS" ] || fail 1 "PR not found"
[ "$STATUS" = abandoned ] && fail 5 "PR is abandoned"

TIP=$(prr_get "$B/iterations?$V" | jq -r '.value | last | .sourceRefCommit.commitId // empty')
if [ -n "$EXPECT_TIP" ] && { [ -z "$TIP" ] || [ "${TIP:0:${#EXPECT_TIP}}" != "$EXPECT_TIP" ]; }; then
  fail 3 "source tip moved: reviewed ${EXPECT_TIP:0:10}, live ${TIP:0:10} — re-check the points before posting"
fi

live_allowed() { # $1 = comment | vote
  case "$POST_MODE" in
    comment+vote) return 0 ;;
    comment) [ "$1" = comment ] ;;
    *) return 1 ;;
  esac
}

outbox() { # $1 = kind, $2 = method, $3 = url, $4 = body
  mkdir -p "$STATE_DIR/outbox"
  local f; f="$STATE_DIR/outbox/$(date -u +%Y%m%dT%H%M%SZ)-$1-$PRID.json"
  jq -n --arg k "$1" --arg m "$2" --arg u "$3" --argjson b "$4" --arg mode "$POST_MODE" \
    '{kind:$k, method:$m, url:$u, body:$b, postMode:$mode}' > "$f"
  jq -cn --arg k "$1" --argjson pr "$PRID" --arg f "$f" --arg mode "$POST_MODE" '{ok:true,kind:$k,pr:$pr,mode:"dry-run",postMode:$mode,outbox:$f}'
}

content_of() { # $1 = file → content with marker, wording checked
  [ -f "$1" ] || fail 2 "content file not found: $1"
  local c; c=$(cat "$1")
  [ -n "${c//[[:space:]]/}" ] || fail 2 "content file is empty"
  if [ "${PRR_ALLOW_TERMS:-0}" != 1 ] && printf '%s' "$c" | grep -qiE \
     'claude|anthropic|chatgpt|openai|copilot|🤖|\bLLM\b|revue (automatisée|générée|automatique)|(générée|rédigée) (automatiquement|par (une |l.)?(ia|outil))|(auto(matically)?[- ]generated|ai[- ]generated|automated) review|review (was )?generated'; then
    fail 4 "content mentions an AI vendor or says the review is generated — reviews must read as ordinary reviews"
  fi
  case "$c" in *"$PR_MARKER"*) ;; *) c="$PR_MARKER"$'\n'"$c" ;; esac
  printf '%s' "$c"
}

case "$KIND" in
  thread)
    FILE="${ARGS[2]:-}"; [ -n "$FILE" ] || usage
    C=$(content_of "$FILE"); rc=$?; [ "$rc" -eq 0 ] || { echo "$C"; exit "$rc"; }
    BODY=$(jq -cn --arg c "$C" '{comments:[{parentCommentId:0,content:$c,commentType:1}],status:1}')
    if live_allowed comment; then
      R=$(prr_curl -X POST -H "Content-Type: application/json" -d "$BODY" "$B/threads?$V")
      TID=$(echo "$R" | jq -r '.id // empty')
      [ -n "$TID" ] || fail 1 "thread not created: $(echo "$R" | jq -r '.message // "unknown error"' | head -c 200)"
      jq -cn --argjson pr "$PRID" --argjson t "$TID" --arg s "$STATUS" '{ok:true,kind:"thread",pr:$pr,mode:"live",threadId:$t,prStatus:$s}'
    else outbox thread POST "$B/threads?$V" "$BODY"; fi
    ;;
  reply)
    TID="${ARGS[2]:-}"; FILE="${ARGS[3]:-}"; [ -n "$TID" ] && [ -n "$FILE" ] || usage
    C=$(content_of "$FILE"); rc=$?; [ "$rc" -eq 0 ] || { echo "$C"; exit "$rc"; }
    if [ -z "$PARENT" ]; then
      PARENT=$(prr_get "$B/threads/$TID?$V" | jq -r '[.comments[]? | select(.parentCommentId == 0)][0].id // 1')
    fi
    # replies take a bare comment object; the {comments:[…]} wrapper is for new threads only
    BODY=$(jq -cn --arg c "$C" --argjson p "$PARENT" '{parentCommentId:$p,content:$c,commentType:1}')
    if live_allowed comment; then
      R=$(prr_curl -X POST -H "Content-Type: application/json" -d "$BODY" "$B/threads/$TID/comments?$V")
      CID=$(echo "$R" | jq -r '.id // empty')
      [ -n "$CID" ] || fail 1 "reply not posted: $(echo "$R" | jq -r '.message // "unknown error"' | head -c 200)"
      jq -cn --argjson pr "$PRID" --argjson t "$TID" --argjson c "$CID" '{ok:true,kind:"reply",pr:$pr,mode:"live",threadId:$t,commentId:$c}'
    else outbox reply POST "$B/threads/$TID/comments?$V" "$BODY"; fi
    ;;
  vote|add-required)
    if [ "$KIND" = add-required ]; then VOTE=0; else VOTE="${ARGS[2]:-}"; fi
    case "$VOTE" in 10|0|-5) ;; 5) [ "$POLICY_PROFILE" = standard ] || fail 2 "+5 is not used with POLICY_PROFILE=strict (any point → -5, zero points → +10)";;
      -10) fail 2 "-10 (rejected) is never used; vote -5 (waiting for the author)";; *) fail 2 "invalid vote: $VOTE";; esac
    [ "$AUTHOR_ID" = "$ME" ] && fail 6 "self-authored PR: Azure DevOps refuses the author's vote — comment only"
    [ "$STATUS" = completed ] && fail 5 "PR already merged: post the review as post-merge feedback, no vote"
    [ "$DRAFT" = true ] && [ "$VOTE" != 0 ] && fail 2 "Draft PR: comment only, the only allowed vote is 0 (required reviewer)"
    # an approval is bound to the exact commit that was reviewed
    if [ "$VOTE" = 10 ]; then
      [[ "$EXPECT_TIP" =~ ^[0-9a-f]{40}$ ]] || fail 2 "+10 needs --expect-tip <full 40-character SHA of the reviewed commit>"
      [ "$TIP" = "$EXPECT_TIP" ] || fail 3 "source tip moved: reviewed ${EXPECT_TIP:0:10}, live ${TIP:0:10}"
    fi
    REVIEWED="${EXPECT_TIP:-$TIP}"; [ "${#REVIEWED}" -lt "${#TIP}" ] && REVIEWED="$TIP"
    BODY=$(jq -cn --argjson v "$VOTE" '{vote:$v,isRequired:true}')
    if live_allowed vote; then
      R=$(prr_curl -X PUT -H "Content-Type: application/json" -d "$BODY" "$B/reviewers/$ME?$V")
      echo "$R" | jq -e '.id' >/dev/null 2>&1 || fail 1 "vote refused: $(echo "$R" | jq -r '.message // "unknown error"' | head -c 200)"
      LIVE=$(prr_get "$B?$V" | jq --arg me "$ME" '[.reviewers[]? | select(.id == $me)][0] | {vote, isRequired}')
      # a push during the vote: the vote no longer applies to what was reviewed → record no tip
      AFTER=$(prr_get "$B/iterations?$V" | jq -r '.value | last | .sourceRefCommit.commitId // empty')
      MOVED=false; [ "$AFTER" = "$TIP" ] || { MOVED=true; REVIEWED=""; }
      jq -cn --argjson pr "$PRID" --arg r "$REPO" --argjson v "$VOTE" --arg tip "$REVIEWED" --arg d "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{id:$pr, repo:$r, vote:$v, tip:$tip, date:$d}' | tee -a "$(prr_ledger_file)" >> "$STATE_DIR/votes.jsonl"
      jq -cn --arg k "$KIND" --argjson pr "$PRID" --argjson v "$VOTE" --argjson live "$LIVE" --argjson moved "$MOVED" \
        '{ok:(($live.vote == $v) and ($moved | not)), kind:$k, pr:$pr, mode:"live", vote:$v, live:$live}
         + (if $moved then {error:"source tip moved during the vote: re-review the new commits"} else {} end)'
    else outbox "$KIND" PUT "$B/reviewers/$ME?$V" "$BODY"; fi
    ;;
  reopen)
    TID="${ARGS[2]:-}"; [ -n "$TID" ] || usage
    BODY='{"status":"active"}'
    if live_allowed comment; then
      R=$(prr_curl -X PATCH -H "Content-Type: application/json" -d "$BODY" "$B/threads/$TID?$V")
      echo "$R" | jq -e '.id' >/dev/null 2>&1 || fail 1 "thread not reopened"
      jq -cn --argjson pr "$PRID" --argjson t "$TID" '{ok:true,kind:"reopen",pr:$pr,mode:"live",threadId:$t}'
    else outbox reopen PATCH "$B/threads/$TID?$V" "$BODY"; fi
    ;;
  *) usage ;;
esac
