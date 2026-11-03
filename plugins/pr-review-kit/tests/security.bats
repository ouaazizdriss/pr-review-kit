#!/usr/bin/env bats
# Guards added in 1.0.2: read-only API access limited to the organisation, merge only of the
# approved commit, other reviewers' threads never resolved by the kit.
load helpers

setup() {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/xstate"
  setup_workspace
  # private copy of the fixtures, so a test can change the live PR
  cp -r "$FIXTURES" "$BATS_TEST_TMPDIR/fx"; export FIXTURES="$BATS_TEST_TMPDIR/fx"
}

live_tip() { # set the live source tip of PR 101
  jq --arg t "$1" '.lastMergeSourceCommit = {commitId: $t}' "$FIXTURES/pr-101.json" > "$FIXTURES/p" && mv "$FIXTURES/p" "$FIXTURES/pr-101.json"
}
approved() { # record a vote in the protected ledger, as post.sh does
  mkdir -p "$XDG_STATE_HOME/pr-review-kit"
  echo "{\"id\":101,\"repo\":\"svc-a\",\"vote\":$2,\"tip\":\"$1\",\"date\":\"2026-10-03T09:00:00Z\"}" >> "$XDG_STATE_HOME/pr-review-kit/votes-org-Proj.jsonl"; }

@test "ado-get: relative path resolves to the organisation's project API" {
  run bash "$S/ado-get.sh" "git/pullrequests?searchCriteria.status=active&api-version=7.0"
  [ "$status" -eq 0 ]
  [ "$(jq '.value | length' <<<"$output")" -gt 0 ]
}

@test "ado-get: refuses another organisation, another host and plain http" {
  run bash "$S/ado-get.sh" "https://dev.azure.com/other-org/x/_apis/projects"
  [ "$status" -eq 2 ]
  run bash "$S/ado-get.sh" "https://evil.example/_apis"
  [ "$status" -eq 2 ]
  run bash "$S/ado-get.sh" "http://dev.azure.com/org/x"
  [ "$status" -eq 2 ]
  run bash "$S/ado-get.sh" "https://dev.azure.com/org@evil.example/x"
  [ "$status" -eq 2 ]
}

@test "merge-pr: no recorded approval → refused" {
  live_tip aaaa1111
  run bash "$S/merge/merge-pr.sh" svc-a 101 --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"no approval recorded"* ]]
}

@test "merge-pr: push after the approval → refused" {
  live_tip bbbb2222; approved aaaa1111 10
  run bash "$S/merge/merge-pr.sh" svc-a 101 --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"source tip moved"* ]]
}

@test "merge-pr: approval later reset to -5 → refused even with the same tip" {
  live_tip aaaa1111; approved aaaa1111 10; approved aaaa1111 -5
  run bash "$S/merge/merge-pr.sh" svc-a 101 --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"no approval recorded"* ]]
}

@test "merge-pr: approved tip unchanged → dry-run OK" {
  live_tip aaaa1111; approved aaaa1111 10
  run bash "$S/merge/merge-pr.sh" svc-a 101 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == "OK dry-run"* ]]
}

@test "merge-pr: another reviewer's active thread blocks the merge and is not resolved" {
  live_tip aaaa1111; approved aaaa1111 10
  jq '.value = [{"id":77,"status":"active","comments":[{"id":1,"commentType":"text","author":{"id":"someone-else"},"content":"please fix"}]}]' \
    "$FIXTURES/threads-101.json" > "$FIXTURES/t" && mv "$FIXTURES/t" "$FIXTURES/threads-101.json"
  run bash "$S/merge/merge-pr.sh" svc-a 101
  [ "$status" -eq 1 ]
  [[ "$output" == *"active thread(s) from other reviewers: 77"* ]]
  ! grep -q "threads/77" "$CURL_LOG"
}

@test "use-workspace: writes the exact kit rule into settings.local.json and keeps other settings" {
  echo '{"permissions":{"allow":["Bash(npm *)","Bash(bash /old/pr-review-kit/0.9/scripts/*)"]},"x":1}' > "$WS/.claude/settings.local.json"
  run bash "$S/use-workspace.sh" "$WS"
  [ "$status" -eq 0 ]
  run jq -r '.permissions.allow[]' "$WS/.claude/settings.local.json"
  [[ "$output" == *"Bash(npm *)"* ]]
  [[ "$output" == *"Bash(bash $S/*)"* ]]
  [[ "$output" != *"/old/pr-review-kit/"* ]]
  [ "$(jq -r .x "$WS/.claude/settings.local.json")" = 1 ]
}

@test "show-config reports today's date" {
  run bash "$S/show-config.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r .today <<<"$output")" = "$(date +%F)" ]
}

@test "skills and workspace settings never allow jq, date, git or curl" {
  ! grep -hE '^\s+- .*Bash\((jq|date|git|curl)' "$KIT"/skills/*/SKILL.md
  run jq -r '.permissions.allow[]' "$KIT/templates/workspace-settings.json"
  [[ "$output" != *"Bash(jq"* && "$output" != *"Bash(date"* && "$output" != *"Bash(git"* && "$output" != *"Bash(curl"* ]]
}

@test "post.sh: a cast vote is also written to the protected ledger outside the workspace" {
  POST_MODE_TEST=comment+vote setup_workspace
  bash "$S/post.sh" vote svc-a 101 -5 >/dev/null 2>&1 || true
  [ -f "$XDG_STATE_HOME/pr-review-kit/votes-org-Proj.jsonl" ]
}

@test "merge-pr: an approval forged in state/votes.jsonl is ignored" {
  live_tip aaaa1111
  echo '{"id":101,"repo":"svc-a","vote":10,"tip":"aaaa1111","date":"2026-10-03T09:00:00Z"}' > "$WS/state/votes.jsonl"
  run bash "$S/merge/merge-pr.sh" svc-a 101 --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"no approval recorded"* ]]
}

@test "merge-pr: --expect-tip is refused without a terminal" {
  live_tip aaaa1111
  run bash "$S/merge/merge-pr.sh" svc-a 101 --dry-run --expect-tip aaaa1111 </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"interactive terminal"* ]]
}

@test "a workspace inside state/ is refused (config.env is shell code)" {
  mkdir -p "$WS/state/evil"; cp "$WS/config.env" "$WS/state/evil/config.env"
  PRR_WORKSPACE="$WS/state/evil" run bash "$S/show-config.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing a workspace"* ]]
}

full_tip() { # make the live tip of PR 101 a full 40-character SHA
  T40=0123456789abcdef0123456789abcdef01234567
  printf '{"value":[{"id":1,"sourceRefCommit":{"commitId":"%s"},"commonRefCommit":{"commitId":"base0000"}}]}' "$T40" > "$FIXTURES/iterations-101.json"
}

@test "post.sh: +10 without the full reviewed SHA is refused" {
  full_tip
  run bash "$S/post.sh" vote svc-a 101 10
  [ "$status" -eq 2 ]
  run bash "$S/post.sh" vote svc-a 101 10 --expect-tip 0123456789
  [ "$status" -eq 2 ]
  [[ "$output" == *"full 40-character SHA"* ]]
}

@test "post.sh: +10 records the reviewed SHA in the protected ledger" {
  full_tip
  sed -i 's|^POST_MODE=.*|POST_MODE="comment+vote"|' "$WS/config.env"
  run bash "$S/post.sh" vote svc-a 101 10 --expect-tip "$T40"
  [ "$(jq -r .tip "$XDG_STATE_HOME/pr-review-kit/votes-org-Proj.jsonl")" = "$T40" ]
  [ "$(jq -r .vote "$XDG_STATE_HOME/pr-review-kit/votes-org-Proj.jsonl")" = 10 ]
}

@test "post.sh: +10 against a moved tip is refused" {
  full_tip
  run bash "$S/post.sh" vote svc-a 101 10 --expect-tip ffffffffffffffffffffffffffffffffffffffff
  [ "$status" -eq 3 ]
}
