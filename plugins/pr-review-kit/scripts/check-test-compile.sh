#!/usr/bin/env bash
# check-test-compile.sh <repo> <prId>
# Verifies that a Spring Boot (Maven) PR's main + unit-test sources COMPILE at the PR
# source commit (`mvn test-compile`, tests not executed). To separate PR-introduced
# breakage from local-environment issues (internal artifacts that only exist in the
# local ~/.m2), the BASE commit is compiled too when the
# source fails. Read-only against Azure DevOps (GET/fetch only). Never prints the PAT.
#
# Output JSON: {repo,prId,src,base,build,source:{ok,phase,errors[]},base:{ok,phase},verdict}
#   verdict = "ok"                 -> tests compile
#           | "pr-broken"          -> source fails, base compiles  => 🟠 MAJEUR (bloquant)
#           | "already-broken"     -> source AND base fail with compile errors (pre-existing)
#           | "env-unverifiable"   -> dependency resolution failed (local env), not the PR's fault
#           | "not-maven"          -> no pom.xml (not a Maven Spring Boot project)
#           | "build-files-changed" -> the PR changes the build itself: NOT built (see below)
#
# Safety: building runs code chosen by the PR author (Maven plugins and extensions, annotation
# processors). The check therefore
#   - refuses to build a PR that changes pom.xml, .mvn/, mvnw*, a Maven settings file or an
#     annotation-processor registration (verdict "build-files-changed": review those by hand);
#     TC_ALLOW_BUILD_CHANGES=true overrides this, only for repositories whose authors you trust;
#   - runs mvn with an EMPTY environment (no AZURE_DEVOPS_PAT, ANTHROPIC_API_KEY, JIRA_PAT, …):
#     only PATH, HOME, JAVA_HOME, MAVEN_HOME and MAVEN_OPTS are passed;
#   - builds offline when TC_OFFLINE=true (needs every dependency already in ~/.m2).
# For stronger isolation, run the kit itself in a container or on a throwaway CI agent.
set -uo pipefail

REPO="${1:?usage: check-test-compile.sh <repo> <prId>}"
PRID="${2:?usage: check-test-compile.sh <repo> <prId>}"
TIMEOUT="${TC_TIMEOUT:-900}"

. "$(dirname "$0")/lib/common.sh"
prr_load
B="$ADO_REPOS_BASE"
GURL="$ADO_GIT_WEB/$REPO"

err() { echo "{\"repo\":\"$REPO\",\"prId\":$PRID,\"error\":$(jq -Rn --arg m "$1" '$m')}"; exit 0; }

ITERS=$(curl -s -H "Authorization: Basic $AUTH" "$B/$REPO/pullRequests/$PRID/iterations?api-version=7.0")
SRC=$(echo "$ITERS" | jq -r '.value | last | .sourceRefCommit.commitId // empty')
BASE=$(echo "$ITERS" | jq -r '.value | last | .commonRefCommit.commitId // empty')
[ -z "$SRC" ] && err "cannot resolve source commit (PR $PRID / $REPO)"

# files that change what the build executes → do not build (unless explicitly allowed)
LASTIT=$(echo "$ITERS" | jq -r '.value | last | .id // empty')
CHANGED=$(curl -s -H "Authorization: Basic $AUTH" "$B/$REPO/pullRequests/$PRID/iterations/$LASTIT/changes?api-version=7.0" \
  | jq -r '.changeEntries[]? | .item.path // empty')
[ -z "$LASTIT" ] || [ -n "$CHANGED" ] || err "cannot list the changed files (PR $PRID / $REPO)"
BUILD_RE='(^|/)(pom\.xml|mvnw|mvnw\.cmd|settings\.xml|settings-security\.xml|toolchains\.xml)$|(^|/)\.mvn/|META-INF/services/javax\.annotation\.processing\.Processor$'
BUILD_FILES=$(printf '%s\n' "$CHANGED" | grep -E "$BUILD_RE" | sort -u | head -20)
if [ -n "$BUILD_FILES" ] && [ "${TC_ALLOW_BUILD_CHANGES:-false}" != true ]; then
  jq -n --arg r "$REPO" --argjson p "$PRID" --arg s "$SRC" --arg f "$BUILD_FILES" \
    '{repo:$r,prId:$p,src:$s[0:10],verdict:"build-files-changed",buildFiles:($f|split("\n"))}'
  exit 0
fi

WD=$(mktemp -d "${TMPDIR:-/tmp}/tcpr.XXXXXX")
trap 'rm -rf "$WD"' EXIT

checkout() { # $1=commit $2=dir
  ( mkdir -p "$2" && cd "$2" && git init -q && git remote add origin "$GURL" \
    && git -c http.extraHeader="Authorization: Basic $AUTH" fetch -q --depth 1 origin "$1" \
    && git checkout -q "$1" ) >/dev/null 2>&1
}

# build $1=dir $2=log ; echoes phase: ok | compile | deps | other
build() {
  if [ ! -f "$1/pom.xml" ]; then echo "not-maven"; return; fi
  local off=(); [ "${TC_OFFLINE:-false}" = true ] && off=(-o)
  ( cd "$1" && env -i PATH="$PATH" HOME="$HOME" LANG=C.UTF-8 \
      ${JAVA_HOME:+JAVA_HOME="$JAVA_HOME"} ${MAVEN_HOME:+MAVEN_HOME="$MAVEN_HOME"} ${MAVEN_OPTS:+MAVEN_OPTS="$MAVEN_OPTS"} \
      timeout "$TIMEOUT" mvn -B -q -ntp "${off[@]}" -DskipTests -Dmaven.test.skip=false \
      -Dspotless.check.skip=true -Dcheckstyle.skip=true -Djacoco.skip=true test-compile ) >"$2" 2>&1
  local rc=$?
  if [ $rc -eq 0 ]; then echo ok
  elif grep -qE "COMPILATION ERROR|Compilation failure|\[ERROR\] .*\.java:\[[0-9]+" "$2"; then echo compile
  elif grep -qE "Could not resolve dependencies|Non-resolvable parent POM|Could not find artifact|could not be resolved" "$2"; then echo deps
  elif [ $rc -eq 124 ]; then echo timeout
  else echo other; fi
}

errors_json() { # compile errors, paths relative to the checkout
  grep -E "\[ERROR\] .*\.java:\[[0-9]+" "$1" | sed -E "s#$2/##; s#^\[ERROR\] ##" | sort -u | head -40 \
    | jq -R . | jq -s .
}

checkout "$SRC" "$WD/src" || err "git checkout failed (commit ${SRC:0:8})"
SP=$(build "$WD/src" "$WD/src.log")
[ "$SP" = "not-maven" ] && { jq -n --arg r "$REPO" --argjson p "$PRID" '{repo:$r,prId:$p,verdict:"not-maven"}'; exit 0; }
SERR=$(errors_json "$WD/src.log" "$WD/src")
STAIL=$(grep -E "^\[ERROR\]" "$WD/src.log" | head -8 | jq -R . | jq -s .)

BP="skipped"
if [ "$SP" != "ok" ] && [ -n "$BASE" ]; then
  if checkout "$BASE" "$WD/base"; then BP=$(build "$WD/base" "$WD/base.log"); else BP="checkout-failed"; fi
fi

# confirm a PR-attributed failure once: transient local ~/.m2 states (internal jar being
# re-installed concurrently) produce spurious "cannot find symbol" on the first build.
if [ "$SP" = "compile" ] && [ "$BP" = "ok" ]; then
  SP=$(build "$WD/src" "$WD/src.log")
  SERR=$(errors_json "$WD/src.log" "$WD/src")
  STAIL=$(grep -E "^\[ERROR\]" "$WD/src.log" | head -8 | jq -R . | jq -s .)
fi

case "$SP" in
  ok) V=ok ;;
  compile) case "$BP" in ok) V=pr-broken ;; compile) V=already-broken ;; *) V=pr-broken-unconfirmed ;; esac ;;
  deps|timeout|other) V=env-unverifiable ;;
esac

jq -n --arg r "$REPO" --argjson p "$PRID" --arg s "$SRC" --arg b "$BASE" \
  --arg sp "$SP" --arg bp "$BP" --arg v "$V" --argjson se "$SERR" --argjson st "$STAIL" \
  '{repo:$r,prId:$p,src:$s[0:10],base:$b[0:10],
    source:{ok:($sp=="ok"),phase:$sp,errors:$se,errorTail:(if $sp=="ok" then [] else $st end)},
    base:{phase:$bp},verdict:$v}'
