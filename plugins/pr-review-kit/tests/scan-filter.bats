#!/usr/bin/env bats
load helpers

setup() { setup_workspace; }

reasons_of() { bash "$S/filter.sh" --json | jq -r --argjson id "$1" 'select(.id == $id) | .reasons | join(",")'; }

@test "scan keeps the allow-listed PRs and records state" {
  run bash "$S/scan.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WS/state/state.jsonl")" -eq 4 ]
  [ "$(jq -r 'select(.id == 101) | .myLastMarked' "$WS/state/state.jsonl")" = "2026-10-03T09:00:00Z" ]
  [ "$(jq -r 'select(.id == 103) | .selfAuthored' "$WS/state/state.jsonl")" = "true" ]
  [ "$(jq -r 'select(.id == 101) | .ticket' "$WS/state/state.jsonl")" = "ABC-1" ]
}

@test "filter: reviewed and unchanged PR is not a candidate; new ones are" {
  bash "$S/scan.sh" 2>/dev/null
  [ -z "$(reasons_of 101)" ]
  [ "$(reasons_of 102)" = "new" ]
  [[ "$(reasons_of 104)" == *"no-ticket"* ]]
}

@test "filter: a vote reset on the same tip is detected" {
  echo '{"id":101,"repo":"svc-a","vote":-5,"tip":"bbbb2222","date":"2026-10-03T09:00:01Z"}' > "$WS/state/votes.jsonl"
  bash "$S/scan.sh" 2>/dev/null
  [[ "$(reasons_of 101)" == *"reset"* ]]
}

@test "filter: a push after the last vote is detected through the ledger" {
  echo '{"id":101,"repo":"svc-a","vote":10,"tip":"aaaa1111","date":"2026-10-01T09:00:00Z"}' > "$WS/state/votes.jsonl"
  bash "$S/scan.sh" 2>/dev/null
  [[ "$(reasons_of 101)" == *"push"* ]]
}

@test "filter: excluded PRs are never candidates" {
  echo 'EXCLUDED_PRS="102 104"' >> "$WS/config.env"
  bash "$S/scan.sh" 2>/dev/null
  [ -z "$(reasons_of 102)" ]
  [ -z "$(reasons_of 104)" ]
}
