#!/usr/bin/env bash
# show-config.sh [--no-auth] — print the effective, non-secret configuration as JSON:
# workspace paths, Azure DevOps target, policy settings, repository kinds, the reviewer
# identity (unless --no-auth), which secrets are present (true/false, never the value),
# and the policy files to read. Skills call it once at the start of a run.
set -uo pipefail
. "$(dirname "$0")/lib/common.sh"
if [ "${1:-}" = "--no-auth" ]; then prr_load --no-auth; ME=""; else prr_load; ME=$(prr_reviewer_id); fi
P="$PRR_PLUGIN_DIR/policy"
jq -n \
  --arg ws "$PRR_WORKSPACE" --arg state "$STATE_DIR" --arg reviews "$REVIEWS_DIR" --arg history "$HISTORY_FILE" \
  --arg prefix "$REVIEW_FILE_PREFIX" --arg allow "$REPO_ALLOWLIST_FILE" \
  --arg org "$ADO_ORG" --arg proj "$ADO_PROJECT" --arg web "$ADO_GIT_WEB" --arg me "$ME" \
  --arg lang "$REVIEW_LANGUAGE" --arg profile "$POLICY_PROFILE" --arg mode "$POST_MODE" \
  --arg marker "$PR_MARKER" --arg ticket "$TICKET_KEY_REGEX" --arg tests "${UNIT_TESTS_BLOCKING:-true}" \
  --arg scanners "${SCANNERS:-semgrep trivy mvn}" --arg sql "${SQL_REPOS:-}" --arg lib "${LIBRARY_REPOS:-}" \
  --arg front "${FRONT_REPOS:-}" --arg sqldocs "${SQL_PROCEDURE_DOCS:-}" --arg team "${TEAM_GROUP_ID:-}" \
  --arg teamname "${TEAM_NAME:-}" --arg excluded "${EXCLUDED_PRS:-}" --arg jira "${JIRA_BASE:-}" \
  --arg par "${REVIEW_PARALLEL_AGENTS:-1}" --arg model "${REVIEW_AGENT_MODEL:-}" \
  --arg relpat "${RELEASE_BRANCH_PATTERN:-release/*}" --arg defbr "${DEFAULT_BRANCH:-develop}" \
  --argjson hasAdo "$([ -n "${AZURE_DEVOPS_PAT:-}" ] && echo true || echo false)" \
  --argjson hasMerge "$([ -n "${AZURE_DEVOPS_MERGE_PAT:-}" ] && echo true || echo false)" \
  --argjson hasJira "$([ -n "${JIRA_PAT:-}" ] && echo true || echo false)" \
  --argjson hasChat "$([ -n "${GCHAT_WEBHOOK_URL:-}" ] && echo true || echo false)" \
  --arg p "$P" --arg notes "$PRR_WORKSPACE/team-notes.md" --arg today "$(date +%F)" '
  def words: split(" ") | map(select(length > 0));
  { today:$today, workspace:$ws, stateDir:$state, reviewsDir:$reviews, historyFile:$history, reviewFilePrefix:$prefix,
    allowlist:$allow, teamNotes:$notes,
    ado:{org:$org, project:$proj, gitWeb:$web, reviewerId:$me},
    policy:{language:$lang, profile:$profile, postMode:$mode, marker:$marker, ticketKeyRegex:$ticket,
            unitTestsBlocking:($tests == "true"), scanners:($scanners|words), sqlProcedureDocs:($sqldocs|words)},
    repos:{sql:($sql|words), library:($lib|words), front:($front|words)},
    team:{groupId:$team, name:$teamname}, excludedPrs:($excluded|words),
    jira:{base:$jira, enabled:($jira != "")},
    loop:{parallelAgents:($par|tonumber? // 1), agentModel:$model},
    release:{pattern:$relpat, defaultBranch:$defbr},
    secretsPresent:{AZURE_DEVOPS_PAT:$hasAdo, AZURE_DEVOPS_MERGE_PAT:$hasMerge, JIRA_PAT:$hasJira, GCHAT_WEBHOOK_URL:$hasChat},
    policyFiles:{core:($p+"/core-rules.md"), checklist:($p+"/review-checklist.md"), sql:($p+"/sql-migrations.md"),
                 merge:($p+"/merge-release.md"), profile:($p+"/profiles/"+$profile+".md")} }'
