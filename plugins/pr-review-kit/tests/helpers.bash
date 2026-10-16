# Shared setup: a throw-away workspace, the fake curl first on PATH, no real secrets.
KIT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
S="$KIT/scripts"

setup_workspace() {
  WS="$BATS_TEST_TMPDIR/ws"
  PRR_WORKSPACE="$WS" bash "$S/init-workspace.sh" "$WS" --no-pointer >/dev/null
  cat > "$WS/config.env" <<CFG
ADO_ORG="org"
ADO_PROJECT="Proj"
TICKET_KEY_REGEX='ABC-[0-9]+'
REVIEW_LANGUAGE="en"
POLICY_PROFILE="strict"
POST_MODE="${POST_MODE_TEST:-dry-run}"
PR_MARKER="<!-- pr-review:test -->"
SQL_REPOS="sql"
CFG
  printf 'svc-a\n# comment\n\nsql\n' > "$WS/repos.allowlist"
  export PRR_WORKSPACE="$WS"
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg"
  export AZURE_DEVOPS_PAT="test-token"
  export FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"; : > "$CURL_LOG"
  export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
  unset JIRA_BASE JIRA_PAT GCHAT_WEBHOOK_URL REVIEWER_ID
}

body_file() { f="$BATS_TEST_TMPDIR/body.md"; printf '%s\n' "$@" > "$f"; echo "$f"; }
