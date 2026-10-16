#!/usr/bin/env bats
load helpers

setup() { setup_workspace; }

@test "show-config prints the effective configuration and the reviewer id" {
  run bash "$S/show-config.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r .ado.reviewerId <<<"$output")" = "me-0001" ]
  [ "$(jq -r .policy.postMode <<<"$output")" = "dry-run" ]
  [ "$(jq -r '.repos.sql[0]' <<<"$output")" = "sql" ]
  [ "$(jq -r .secretsPresent.AZURE_DEVOPS_PAT <<<"$output")" = "true" ]
}

@test "the generic marker is refused" {
  sed -i 's|^PR_MARKER=.*|PR_MARKER="<!-- pr-review -->"|' "$WS/config.env"
  run bash "$S/show-config.sh" --no-auth
  [ "$status" -eq 2 ]
  [[ "$output" == *"unique to your team"* ]]
}

@test "an invalid POST_MODE is refused" {
  sed -i 's|^POST_MODE=.*|POST_MODE="yes"|' "$WS/config.env"
  run bash "$S/show-config.sh" --no-auth
  [ "$status" -eq 2 ]
  [[ "$output" == *"POST_MODE"* ]]
}

@test "an unsubstituted user_config placeholder falls back to the pointer file" {
  mkdir -p "$XDG_CONFIG_HOME/pr-review-kit"; echo "$WS" > "$XDG_CONFIG_HOME/pr-review-kit/workspace"
  PRR_WORKSPACE='${user_config.workspace}' run bash "$S/show-config.sh" --no-auth
  [ "$status" -eq 0 ]
  [ "$(jq -r .workspace <<<"$output")" = "$WS" ]
}

@test "a missing token is reported, not printed" {
  unset AZURE_DEVOPS_PAT
  run bash "$S/show-config.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"AZURE_DEVOPS_PAT is not set"* ]]
}

@test "init-workspace never overwrites an existing config" {
  echo 'ADO_ORG="kept"' >> "$WS/config.env"
  run bash "$S/init-workspace.sh" "$WS" --no-pointer
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept     config.env"* ]]
  grep -q 'ADO_ORG="kept"' "$WS/config.env"
}
