#!/usr/bin/env bash
# filter.sh [--json] — read $STATE_DIR/state.jsonl (from scan.sh) and list the PRs that
# need attention, with the reasons. Default output is a table; --json prints one JSON
# object per candidate: {id, repo, ticket, draft, myVote, reasons[], …state fields}.
#
# Reasons:
#   new          never reviewed by this team (no comment carrying the marker)
#   push         a source tip first pushed after my last review (marked comment, or a long
#                unmarked one under my identity), or a tip other than
#                the one my last vote was cast on
#   draft2active published after a Draft-only review, no vote yet
#   reply        a human comment after my last comment, not yet marked as considered
#   owner        a short unmarked comment under my identity = an owner decision to apply
#   conflict     merge conflict with the target while my vote is positive
#   team         the team group is a reviewer and I am not a required reviewer yet
#   reset        my live vote differs from my last cast vote on the same tip (vote reset)
#   no-ticket    non-Draft PR without a ticket key, reminder not posted yet
#
# Peer comments already read are listed in $STATE_DIR/considered.json:
#   [{"id": 1234, "tid": 5678, "d": "2026-10-01T10:00:00Z"}]   (d optional: up to that date)
set -uo pipefail
. "$(dirname "$0")/lib/common.sh"
prr_load --no-auth
MODE=table; [ "${1:-}" = "--json" ] && MODE=json
STATE="$STATE_DIR/state.jsonl"
[ -s "$STATE" ] || prr_die "no state: run scan.sh first"
CONS="$STATE_DIR/considered.json"; [ -f "$CONS" ] || echo '[]' > "$CONS"

out=$(jq -c --slurpfile cons "$CONS" '
  select(.excluded | not)
  | . as $p
  | ($p.humanAfter | map(select(. as $h | ($cons[0] | map(select(.id == $p.id and .tid == $h.tid and ((.d // null) == null or $h.d <= .d))) | length) == 0))) as $ha
  | [ (if $p.myLastMarked == null then "new" else empty end),
      (if $p.myLastMarked != null and (($p.lastPush // "") > ($p.myLastReview // $p.myLastMarked)
           or ($p.lastCast != null and $p.lastCast.tip != $p.tip)) then "push" else empty end),
      (if ($p.draft | not) and $p.myLastMarked != null and (($p.myVote // 0) == 0) and ($p.selfAuthored | not) then "draft2active" else empty end),
      (if ($ha | length) > 0 then "reply" else empty end),
      (if ($p.ownerManual // [] | length) > 0 then "owner" else empty end),
      (if $p.merge == "conflicts" and (($p.myVote // 0) > 0) then "conflict" else empty end),
      (if $p.team and ($p.meReq != true) and ($p.selfAuthored | not) then "team" else empty end),
      (if ($p.draft | not) and ($p.selfAuthored | not) and $p.lastCast != null and $p.lastCast.tip == $p.tip
           and (($p.myVote // 0) != $p.lastCast.vote) then "reset" else empty end),
      (if ($p.draft | not) and $p.ticket == null and (($p.myVote // 0) != -5) and ($p.selfAuthored | not) then "no-ticket" else empty end)
    ] | unique as $r
  | select(($r | length) > 0)
  | $p + {reasons: $r, humanAfterNew: $ha}' "$STATE")

if [ "$MODE" = json ]; then
  [ -n "$out" ] && echo "$out"
else
  if [ -z "$out" ]; then echo "No PR needs attention."; exit 0; fi
  { printf 'ID\tREPO\tDRAFT\tVOTE\tMERGE\tREASONS\tAUTHOR\tTITLE\n'
    echo "$out" | jq -r '[.id, .repo, (.draft|tostring), ((.myVote // "-")|tostring), .merge,
        (.reasons|join(",")), (.author // "")[0:18], (.title // "")[0:50]] | @tsv'
  } | column -t -s $'\t'
fi
