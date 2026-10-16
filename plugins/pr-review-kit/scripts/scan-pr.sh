#!/usr/bin/env bash
# scan-pr.sh <repo> <prId>
# Clones a Azure DevOps PR's source commit, runs Semgrep (SAST) and — when the
# diff touches dependency/IaC/Dockerfile/config files — Trivy (vuln/secret/misconfig),
# scoped to the PR's CHANGED files, and prints a normalized JSON findings report to
# stdout. Findings are ADVISORY candidates: the reviewer must verify each against the
# diff before turning it into a review point. Read-only against Azure DevOps (GET only).
#
# Requires: AZURE_DEVOPS_PAT, git, curl, jq, semgrep, trivy.
# Never prints the PAT. Cleans up the clone on exit.
set -uo pipefail

REPO="${1:?usage: scan-pr.sh <repo> <prId>}"
PRID="${2:?usage: scan-pr.sh <repo> <prId>}"
MAX_FINDINGS="${SCAN_MAX_FINDINGS:-60}"

. "$(dirname "$0")/lib/common.sh"
prr_load
B="$ADO_REPOS_BASE"
GURL="$ADO_GIT_WEB/$REPO"

err() { echo "{\"repo\":\"$REPO\",\"prId\":$PRID,\"error\":$(jq -Rn --arg m "$1" '$m')}"; exit 0; }

# --- resolve latest iteration: source commit + changed files -----------------
ITERS=$(curl -s -H "Authorization: Basic $AUTH" "$B/$REPO/pullRequests/$PRID/iterations?api-version=7.0")
ITERID=$(echo "$ITERS" | jq -r '.value | last | .id // empty')
SRC=$(echo "$ITERS" | jq -r '.value | last | .sourceRefCommit.commitId // empty')
BASE=$(echo "$ITERS" | jq -r '.value | last | .commonRefCommit.commitId // empty')
[ -z "$SRC" ] && err "cannot resolve source commit (PR $PRID / $REPO)"

CHANGES=$(curl -s -H "Authorization: Basic $AUTH" "$B/$REPO/pullRequests/$PRID/iterations/$ITERID/changes?api-version=7.0")
# changed file paths (edit/add only; skip deletes and folders), leading slash stripped
mapfile -t CHANGED < <(echo "$CHANGES" | jq -r '
  .changeEntries[]? | select(.item.isFolder != true)
  | select(.changeType | test("delete") | not)
  | .item.path' | sed 's#^/##' | sort -u)
CHANGED_COUNT=${#CHANGED[@]}

# --- shallow checkout of the source commit -----------------------------------
WD=$(mktemp -d "${TMPDIR:-/tmp}/scanpr.XXXXXX")
trap 'rm -rf "$WD"' EXIT
(
  cd "$WD" && git init -q repo && cd repo && git remote add origin "$GURL"
  git -c http.extraHeader="Authorization: Basic $AUTH" fetch -q --depth 1 origin "$SRC"
  git checkout -q "$SRC"
) 2>/dev/null || err "git checkout failed (commit ${SRC:0:8})"
RD="$WD/repo"

# fetch base commit too (for base-vs-source vuln diff); non-fatal if unavailable
BASE_OK=0
if [ -n "$BASE" ]; then
  ( cd "$RD" && git -c http.extraHeader="Authorization: Basic $AUTH" fetch -q --depth 1 origin "$BASE" \
      && git worktree add -q "$WD/base" "$BASE" ) 2>/dev/null && BASE_OK=1
fi

# existing changed files that are on disk (for path-scoped filtering)
CHANGED_ON_DISK=()
for f in "${CHANGED[@]}"; do [ -f "$RD/$f" ] && CHANGED_ON_DISK+=("$f"); done

# --- Semgrep: scan only the changed source files -----------------------------
SEMGREP_JSON='{"ran":false,"findings":[],"error":null}'
if [ "${#CHANGED_ON_DISK[@]}" -gt 0 ]; then
  SG=$(cd "$RD" && semgrep --config "${SEMGREP_CONFIG:-p/default}" --json --metrics off --quiet \
        --severity ERROR --severity WARNING --timeout 90 --jobs 2 \
        "${CHANGED_ON_DISK[@]}" 2>"$WD/sg.err")
  if [ -n "$SG" ] && echo "$SG" | jq -e . >/dev/null 2>&1; then
    SEMGREP_JSON=$(echo "$SG" | jq --argjson max "$MAX_FINDINGS" '{
      ran:true, error:null,
      findings: ([.results[]? | {
        file:(.path), line:(.start.line),
        severity:(.extra.severity), rule:(.check_id),
        message:(.extra.message // "" | .[0:300]),
        cwe:((.extra.metadata.cwe // []) | if type=="array" then . else [.] end),
        owasp:((.extra.metadata.owasp // []) | if type=="array" then . else [.] end)
      }] | .[0:$max]),
      total: ([.results[]?] | length)
    }')
  else
    SEMGREP_JSON=$(jq -Rn --arg e "$(head -c 300 "$WD/sg.err")" '{ran:false,findings:[],error:$e}')
  fi
fi

# --- Trivy: only if the diff touches deps / IaC / Dockerfile / lockfiles -----
TRIVY_JSON='{"ran":false,"findings":[],"error":null,"reason":"no dependency/IaC/config file in diff"}'
TRIVY_RE='(^|/)(pom\.xml|build\.gradle(\.kts)?|package\.json|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|requirements\.txt|go\.(mod|sum)|Dockerfile[^/]*|.*\.tf|.*\.ya?ml)$'
NEEDS_TRIVY=0
for f in "${CHANGED[@]}"; do [[ "$f" =~ $TRIVY_RE ]] && NEEDS_TRIVY=1 && break; done
if [ "$NEEDS_TRIVY" -eq 1 ]; then
  TV=$(cd "$RD" && trivy fs --scanners vuln,secret,misconfig --format json --quiet \
        --timeout 5m . 2>"$WD/tv.err")
  if [ -n "$TV" ] && echo "$TV" | jq -e . >/dev/null 2>&1; then
    # baseline vuln set (base commit) so we report only PR-INTRODUCED CVEs, not
    # the repo's pre-existing dependency debt. Secret/misconfig stay path-scoped.
    BASE_VULN='[]'
    if [ "$BASE_OK" -eq 1 ]; then
      BV=$(cd "$WD/base" && trivy fs --scanners vuln --format json --quiet --timeout 5m . 2>/dev/null)
      echo "$BV" | jq -e . >/dev/null 2>&1 && \
        BASE_VULN=$(echo "$BV" | jq '[.Results[]?.Vulnerabilities[]? | (.PkgName+"@"+.VulnerabilityID)]')
    fi
    CHJSON=$(printf '%s\n' "${CHANGED[@]}" | jq -R . | jq -s .)
    TRIVY_JSON=$(echo "$TV" | jq \
      --argjson changed "$CHJSON" --argjson basevuln "$BASE_VULN" \
      --argjson max "$MAX_FINDINGS" --argjson basediff "$BASE_OK" '
      def changed(p): ($changed | index(p)) != null;
      { ran:true, error:null, baseDiff:($basediff==1),
        findings: ([
          (.Results[]? as $r
            | ($r.Vulnerabilities[]? | (.PkgName+"@"+.VulnerabilityID) as $k | select(($basevuln | index($k)) == null) | {type:"vuln", file:$r.Target, id:.VulnerabilityID, pkg:.PkgName, severity:.Severity, title:(.Title // .VulnerabilityID)}),
              ($r.Secrets[]? | select(changed($r.Target)) | {type:"secret", file:$r.Target, id:.RuleID, severity:.Severity, title:.Title, line:.StartLine}),
              ($r.Misconfigurations[]? | select(changed($r.Target)) | {type:"misconfig", file:$r.Target, id:.ID, severity:.Severity, title:.Title})
          )
        ] | .[0:$max]) }')
  else
    TRIVY_JSON=$(jq -Rn --arg e "$(head -c 300 "$WD/tv.err")" '{ran:false,findings:[],error:$e}')
  fi
fi

# --- normalized report --------------------------------------------------------
jq -n \
  --arg repo "$REPO" --argjson pr "$PRID" --arg src "$SRC" \
  --argjson changed "$CHANGED_COUNT" \
  --argjson semgrep "$SEMGREP_JSON" --argjson trivy "$TRIVY_JSON" \
  '{repo:$repo, prId:$pr, sourceCommit:$src, changedFiles:$changed, semgrep:$semgrep, trivy:$trivy}'
