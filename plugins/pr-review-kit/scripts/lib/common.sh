#!/usr/bin/env bash
# common.sh — shared helpers for every pr-review-kit script. Source it, do not run it.
#
#   . "$(dirname "$0")/lib/common.sh"      (from scripts/)
#   prr_load                                 loads the team workspace config, or exits 2
#
# Resolution order for the team workspace (where config.env, state/ and reviews live):
#   1. $PRR_WORKSPACE
#   2. the path stored in ~/.config/pr-review-kit/workspace (written by setup)
# Secrets are never read from files: AZURE_DEVOPS_PAT, JIRA_PAT, GCHAT_WEBHOOK_URL,
# AZURE_DEVOPS_MERGE_PAT come from the environment only.

# shellcheck disable=SC2034  # variables are consumed by the scripts that source this file

PRR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRR_SCRIPTS_DIR="$(cd "$PRR_LIB_DIR/.." && pwd)"
PRR_PLUGIN_DIR="$(cd "$PRR_SCRIPTS_DIR/.." && pwd)"
PRR_POINTER_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/pr-review-kit/workspace"
PRR_GENERIC_MARKER='<!-- pr-review -->'
# protected ledger folder, fixed from the CALLER's environment before config.env is sourced
# (config.env is loaded with set -a and could otherwise redirect it)
PRR_LEDGER_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/pr-review-kit"
PRR_CONFIG_KEYS=(ADO_ORG ADO_PROJECT ADO_API_VERSION REPO_ALLOWLIST_FILE EXCLUDED_PRS TEAM_GROUP_ID TEAM_NAME
  SQL_REPOS LIBRARY_REPOS FRONT_REPOS SQL_PROCEDURE_DOCS TICKET_KEY_REGEX REVIEW_LANGUAGE POLICY_PROFILE
  UNIT_TESTS_BLOCKING SCANNERS SEMGREP_CONFIG PR_MARKER PR_MARKER_ALIASES POST_MODE REVIEW_PARALLEL_AGENTS
  REVIEW_AGENT_MODEL REVIEWS_DIR REVIEW_FILE_PREFIX HISTORY_FILE STATE_DIR JIRA_BASE JIRA_EMAIL JIRA_SUBTASK_TYPES
  WFA_MENTION WFA_TITLE WFA_SUBTITLE WFA_NO_TICKET MERGE_ALLOW_BYPASS MERGE_BYPASS_REASON MERGE_DELETE_SOURCE_BRANCH MERGE_COMMIT_TRAILER
  RELEASE_BRANCH_PATTERN DEFAULT_BRANCH DEFAULT_RELEASE_REF DEPLOY_ENVIRONMENTS DEPLOY_DEFAULT_ENV
  DEPLOY_LIBRARY_GROUPS PRODUCTION_ENVS DEPLOY_PIPELINES_FILE GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
  ADO_BASE ADO_REPOS_BASE ADO_GIT_WEB ADO_PROJECT_API ADO_CONNDATA JIRA_BROWSE JIRA_API REVIEWER_ID)

prr_die() { echo "pr-review-kit: $*" >&2; exit 2; }
prr_warn() { echo "pr-review-kit: warning: $*" >&2; }

# JSON error object on stdout (scripts whose callers parse JSON), exit 0 so the caller reads it.
prr_json_error() { jq -cn --arg m "$1" '{error:$m}'; exit 0; }

prr_resolve_workspace() {
  # an unsubstituted ${user_config.workspace} placeholder counts as unset
  case "${PRR_WORKSPACE:-}" in *'${'*) PRR_WORKSPACE="";; esac
  if [ -z "${PRR_WORKSPACE:-}" ] && [ -f "$PRR_POINTER_FILE" ]; then
    PRR_WORKSPACE="$(head -n1 "$PRR_POINTER_FILE")"
  fi
  [ -n "${PRR_WORKSPACE:-}" ] || prr_die "no workspace: set PRR_WORKSPACE or run /pr-review-kit:setup"
  PRR_WORKSPACE="${PRR_WORKSPACE/#\~/$HOME}"
  [ -d "$PRR_WORKSPACE" ] || prr_die "workspace not found: $PRR_WORKSPACE"
  # config.env is sourced as shell code: never accept one from a folder the agent may write to
  case "/$(cd "$PRR_WORKSPACE" && pwd)/" in
    */state/*|*/reviews/*|*/outbox/*) prr_die "refusing a workspace inside a state/ or reviews/ folder: $PRR_WORKSPACE" ;;
  esac
  export PRR_WORKSPACE
}

# prr_load [--no-auth]  — load config.env, validate it, derive URLs, build the auth header.
prr_load() {
  local need_auth=1
  [ "${1:-}" = "--no-auth" ] && need_auth=0
  prr_resolve_workspace
  local cfg="${PRR_CONFIG:-$PRR_WORKSPACE/config.env}"
  [ -f "$cfg" ] || prr_die "config not found: $cfg (copy templates/config.env.example or run setup)"
  # config.env alone decides: drop inherited values of every non-secret key first, so a
  # variable exported in the caller's shell never fills a key the team left unset.
  local key
  for key in "${PRR_CONFIG_KEYS[@]}"; do unset "$key"; done
  set -a
  # shellcheck disable=SC1090
  . "$cfg"
  set +a
  # the one environment override: force a stricter posting mode (e.g. PRR_POST_MODE=dry-run)
  [ -n "${PRR_POST_MODE:-}" ] && POST_MODE="$PRR_POST_MODE"

  local k
  for k in ADO_ORG ADO_PROJECT TICKET_KEY_REGEX PR_MARKER REVIEW_LANGUAGE POST_MODE POLICY_PROFILE; do
    [ -n "${!k:-}" ] || prr_die "config key $k is empty in $cfg"
  done
  case "$POST_MODE" in dry-run|comment|comment+vote) ;; *) prr_die "POST_MODE must be dry-run, comment or comment+vote (got: $POST_MODE)";; esac
  case "$POLICY_PROFILE" in strict|standard) ;; *) prr_die "POLICY_PROFILE must be strict or standard (got: $POLICY_PROFILE)";; esac
  [ "$PR_MARKER" != "$PRR_GENERIC_MARKER" ] || prr_die "PR_MARKER must be unique to your team, e.g. <!-- pr-review:myteam --> (the generic marker is shared by other loops)"

  ADO_API_VERSION="${ADO_API_VERSION:-7.0}"
  ADO_BASE="https://dev.azure.com/${ADO_ORG}/${ADO_PROJECT}/_apis/git"
  ADO_REPOS_BASE="${ADO_BASE}/repositories"
  ADO_PROJECT_API="https://dev.azure.com/${ADO_ORG}/${ADO_PROJECT}/_apis"
  ADO_GIT_WEB="https://dev.azure.com/${ADO_ORG}/${ADO_PROJECT}/_git"
  ADO_CONNDATA="https://dev.azure.com/${ADO_ORG}/_apis/connectionData?api-version=${ADO_API_VERSION}-preview"
  if [ -n "${JIRA_BASE:-}" ]; then
    JIRA_BASE="${JIRA_BASE%/}"
    JIRA_BROWSE="${JIRA_BASE}/browse"
    JIRA_API="${JIRA_BASE}/rest/api/3"
  fi

  REPO_ALLOWLIST_FILE="${REPO_ALLOWLIST_FILE:-repos.allowlist}"
  case "$REPO_ALLOWLIST_FILE" in /*) ;; *) REPO_ALLOWLIST_FILE="$PRR_WORKSPACE/$REPO_ALLOWLIST_FILE";; esac
  STATE_DIR="${STATE_DIR:-$PRR_WORKSPACE/state}"
  REVIEWS_DIR="${REVIEWS_DIR:-$PRR_WORKSPACE/reviews}"
  HISTORY_FILE="${HISTORY_FILE:-$PRR_WORKSPACE/history.md}"
  REVIEW_FILE_PREFIX="${REVIEW_FILE_PREFIX:-review}"
  mkdir -p "$STATE_DIR"

  if [ "$need_auth" = 1 ]; then
    [ -n "${AZURE_DEVOPS_PAT:-}" ] || prr_die "AZURE_DEVOPS_PAT is not set in the environment"
    AUTH=$(printf ":%s" "$AZURE_DEVOPS_PAT" | base64 -w0)
  fi
  export ADO_ORG ADO_PROJECT ADO_API_VERSION ADO_BASE ADO_REPOS_BASE ADO_PROJECT_API ADO_GIT_WEB \
         STATE_DIR REVIEWS_DIR HISTORY_FILE REVIEW_FILE_PREFIX REPO_ALLOWLIST_FILE
}

# prr_ledger_file — the PROTECTED votes ledger: outside the workspace, where the agent cannot
# write (only post.sh appends to it). merge-pr.sh trusts this copy only; state/votes.jsonl is
# the working copy used for detection.
prr_ledger_file() {
  local d="$PRR_LEDGER_DIR" real ws
  mkdir -p "$d" && chmod 700 "$d" || prr_die "cannot create the ledger folder $d"
  [ -L "$d" ] && prr_die "ledger folder is a symbolic link: $d"
  [ -O "$d" ] || prr_die "ledger folder not owned by you: $d"
  real=$(cd "$d" && pwd -P); ws=$(cd "$PRR_WORKSPACE" && pwd -P)
  case "$real/" in "$ws"/*) prr_die "ledger folder inside the workspace: $d" ;; esac
  local f="$real/votes-${ADO_ORG}-${ADO_PROJECT}.jsonl"
  [ -L "$f" ] && prr_die "ledger file is a symbolic link: $f"
  echo "$f"
}

# prr_curl <curl args…> — authenticated curl, 30 s timeout, never echoes the token.
prr_curl() { curl -s -m "${PRR_HTTP_TIMEOUT:-30}" -H "Authorization: Basic $AUTH" "$@"; }

# prr_get <url> — GET with 3 attempts; succeeds only on a JSON body.
prr_get() {
  local out i
  for i in 1 2 3; do
    out=$(prr_curl "$1")
    if [ -n "$out" ] && echo "$out" | jq -e . >/dev/null 2>&1; then echo "$out"; return 0; fi
    sleep 2
  done
  prr_warn "GET failed: ${1%%\?*}"
  return 1
}

# prr_get_list <url> — like prr_get but also requires a .value array (list endpoints).
prr_get_list() {
  local out i
  for i in 1 2 3; do
    out=$(prr_curl "$1")
    if echo "$out" | jq -e '.value|type=="array"' >/dev/null 2>&1; then echo "$out"; return 0; fi
    sleep 2
  done
  prr_warn "list fetch failed: ${1%%\?*}"
  echo '{"value":null}'
  return 1
}

# prr_reviewer_id — id of the identity behind AZURE_DEVOPS_PAT, exported as REVIEWER_ID.
prr_reviewer_id() {
  if [ -z "${REVIEWER_ID:-}" ]; then
    REVIEWER_ID=$(prr_get "$ADO_CONNDATA" | jq -r '.authenticatedUser.id // empty')
    [ -n "$REVIEWER_ID" ] || prr_die "cannot resolve the reviewer id from connectionData (token invalid or expired?)"
  fi
  export REVIEWER_ID
  echo "$REVIEWER_ID"
}

# prr_markers_json — JSON array of the markers that identify this team's review comments
# (PR_MARKER first, then PR_MARKER_ALIASES, '|'-separated, for comments posted before a rename).
prr_markers_json() {
  jq -cn --arg m "$PR_MARKER" --arg a "${PR_MARKER_ALIASES:-}" \
    '[$m] + ($a | split("|") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0)))'
}

# prr_ticket_of <text…> — first ticket key in the arguments (title, branch), or empty.
prr_ticket_of() { printf '%s\n' "$*" | grep -oE "$TICKET_KEY_REGEX" | head -n1; }

# prr_pr_url <repo> <id> — the real web URL of a PR (never a work-item URL).
prr_pr_url() { echo "$ADO_GIT_WEB/$1/pullrequest/$2"; }

# prr_list_contains <space-separated list> <item>
prr_list_contains() { case " $1 " in *" $2 "*) return 0;; esac; return 1; }

# prr_repo_kind <repo> — sql | library | front | backend, from the config lists.
prr_repo_kind() {
  if prr_list_contains "${SQL_REPOS:-}" "$1"; then echo sql
  elif prr_list_contains "${LIBRARY_REPOS:-}" "$1"; then echo library
  elif prr_list_contains "${FRONT_REPOS:-}" "$1"; then echo front
  else echo backend; fi
}
