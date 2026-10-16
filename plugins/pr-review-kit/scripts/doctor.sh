#!/usr/bin/env bash
# doctor.sh — check that everything the kit needs is in place. Read-only. Never prints a secret.
# Exit 0 when every REQUIRED check passes (optional checks only warn), 1 otherwise.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib/common.sh"

FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
section() { printf '\n%s\n' "$*"; }

section "Tools (required)"
for t in bash curl jq git base64 flock column; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "$t is missing"; fi
done
if command -v git >/dev/null 2>&1; then
  gv=$(git --version | grep -oE '[0-9]+\.[0-9]+' | head -n1)
  if [ "$(printf '%s\n2.38\n' "$gv" | sort -V | head -n1)" = "2.38" ]; then ok "git $gv (merge-tree --write-tree available)"
  else bad "git $gv is older than 2.38: check-merge.sh needs git merge-tree --write-tree"; fi
fi
if command -v jq >/dev/null 2>&1; then
  jv=$(jq --version | grep -oE '[0-9]+\.[0-9]+' | head -n1)
  [ "$(printf '%s\n1.6\n' "$jv" | sort -V | head -n1)" = "1.6" ] && ok "jq $jv" || bad "jq $jv is older than 1.6"
fi

section "Tools (optional — the matching check is skipped and reported when missing)"
for t in semgrep:scan-pr.sh trivy:scan-pr.sh mvn:check-test-compile.sh python3:merge/resolve-imports.py whiptail:interactive\ menus google-chrome:PDF\ reports; do
  name=${t%%:*}; use=${t#*:}
  if command -v "$name" >/dev/null 2>&1; then ok "$name ($use)"; else warn "$name not found — $use unavailable"; fi
done

section "Workspace and configuration"
( prr_load --no-auth ) 2>/tmp/prr-doctor.$$ && CFG_OK=1 || CFG_OK=0
if [ "$CFG_OK" = 1 ]; then
  prr_load --no-auth 2>/dev/null
  ok "workspace $PRR_WORKSPACE"
  ok "config: org=$ADO_ORG project=$ADO_PROJECT language=$REVIEW_LANGUAGE profile=$POLICY_PROFILE"
  case "$POST_MODE" in
    dry-run) ok "POST_MODE=dry-run (nothing is posted — switch after the trial period)";;
    comment) warn "POST_MODE=comment (comments are posted, votes are not)";;
    comment+vote) warn "POST_MODE=comment+vote (comments AND votes are posted)";;
  esac
  ok "marker $PR_MARKER"
  if [ -f "$REPO_ALLOWLIST_FILE" ]; then
    n=$(grep -cvE '^\s*(#|$)' "$REPO_ALLOWLIST_FILE" || true)
    [ "$n" -gt 0 ] && ok "allowlist: $n repositories" || bad "allowlist $REPO_ALLOWLIST_FILE is empty"
  else bad "allowlist not found: $REPO_ALLOWLIST_FILE"; fi
  [ -n "${SQL_REPOS:-}${LIBRARY_REPOS:-}${FRONT_REPOS:-}" ] && ok "repo kinds: sql=[${SQL_REPOS:-}] library=[${LIBRARY_REPOS:-}] front=[${FRONT_REPOS:-}]" \
    || warn "SQL_REPOS / LIBRARY_REPOS / FRONT_REPOS are empty: every repo is treated as a back-end service"
else
  bad "$(cat /tmp/prr-doctor.$$)"
fi
rm -f /tmp/prr-doctor.$$

section "Azure DevOps"
if [ -z "${AZURE_DEVOPS_PAT:-}" ]; then bad "AZURE_DEVOPS_PAT is not set"
elif [ "$CFG_OK" = 1 ]; then
  AUTH=$(printf ":%s" "$AZURE_DEVOPS_PAT" | base64 -w0)
  who=$(prr_curl "$ADO_CONNDATA" | jq -r '.authenticatedUser | "\(.providerDisplayName // .customDisplayName // "?")|\(.id // "")"' 2>/dev/null)
  if [ -n "${who#*|}" ]; then ok "token valid — identity: ${who%%|*} (${who#*|})"
  else bad "token rejected by https://dev.azure.com/$ADO_ORG (expired, wrong org, or missing scope)"; fi
  if [ -f "$REPO_ALLOWLIST_FILE" ]; then
    for r in $(grep -vE '^\s*(#|$)' "$REPO_ALLOWLIST_FILE" | head -n 3); do
      c=$(prr_curl -o /dev/null -w '%{http_code}' "$ADO_REPOS_BASE/$r?api-version=$ADO_API_VERSION")
      [ "$c" = 200 ] && ok "repository $r readable" || bad "repository $r: HTTP $c"
    done
    first=$(grep -vE '^\s*(#|$)' "$REPO_ALLOWLIST_FILE" | head -n1)
    c=$(prr_curl -o /dev/null -w '%{http_code}' "$ADO_REPOS_BASE/$first/pullRequests?searchCriteria.status=active&\$top=1&api-version=$ADO_API_VERSION")
    [ "$c" = 200 ] && ok "pull requests readable" || bad "pull requests of $first: HTTP $c"
    if git -c http.extraHeader="Authorization: Basic $AUTH" ls-remote "$ADO_GIT_WEB/$first" HEAD >/dev/null 2>&1; then ok "git fetch over HTTPS works (needed by the check scripts)"
    else bad "git ls-remote $ADO_GIT_WEB/$first failed: the token needs Code (read)"; fi
  fi
fi
[ -n "${AZURE_DEVOPS_MERGE_PAT:-}" ] && ok "AZURE_DEVOPS_MERGE_PAT set (merge-deploy module)" || warn "AZURE_DEVOPS_MERGE_PAT not set — merge-deploy falls back to AZURE_DEVOPS_PAT"

section "Jira"
if [ "$CFG_OK" = 1 ] && [ -n "${JIRA_BASE:-}" ]; then
  if [ -z "${JIRA_PAT:-}" ]; then bad "JIRA_PAT is not set (JIRA_BASE is configured)"
  elif [ -z "${JIRA_EMAIL:-}" ]; then bad "JIRA_EMAIL is empty in config.env"
  else
    c=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -u "$JIRA_EMAIL:$JIRA_PAT" "$JIRA_BASE/rest/api/3/myself")
    [ "$c" = 200 ] && ok "Jira authentication ($JIRA_BASE)" || bad "Jira authentication failed: HTTP $c"
  fi
else warn "Jira not configured — the ticket line is skipped"; fi

section "Google Chat"
[ -n "${GCHAT_WEBHOOK_URL:-}" ] && ok "GCHAT_WEBHOOK_URL set (value not shown)" || warn "GCHAT_WEBHOOK_URL not set — the reminder stays dormant"

echo
if [ "$FAIL" = 0 ]; then echo "doctor: all required checks passed"; else echo "doctor: some required checks failed (✗ above)"; fi
exit "$FAIL"
