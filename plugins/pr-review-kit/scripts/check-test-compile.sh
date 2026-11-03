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
#           | "build-files-changed" -> the PR changes the build itself, or files of a type the
#                                     check does not know: NOT built (see below)
#           | "in-repo-processor"  -> the repository builds its own annotation processor: NOT built
#
# Safety: building runs code chosen by the PR author (Maven plugins and extensions, annotation
# processors). javac itself does not run the compiled code, so the check builds a PR only when
#   - EVERY changed file (all pages of the change list) is a source or resource of a known type
#     that a build does not execute (.java .kt .properties .yml .yaml .sql .md .txt .csv, images) —
#     scripts, package.json, JS or XML may be run by plugins already in the pom — and none is pom.xml, .mvn/, mvnw*, a Maven settings file or an annotation-processor
#     registration (otherwise "build-files-changed": review those files by hand);
#   - the checkout registers no annotation processor of its own (META-INF/services/
#     javax.annotation.processing.Processor in a source tree): such a processor's code is PR-
#     controlled and runs inside the build ("in-repo-processor");
#   TC_ALLOW_BUILD_CHANGES=true lifts both refusals, only for repositories whose authors you trust.
# mvn then runs with an EMPTY environment (only PATH, HOME, JAVA_HOME, MAVEN_HOME, MAVEN_OPTS) and
# offline when TC_OFFLINE=true. Residual risk: a plugin already in the pom that runs project code
# during the build (e.g. exec:java bound before test-compile). This is not a sandbox — a process of the same user can still read
# other processes' environments under /proc — so for untrusted contributors run the kit on a
# throwaway agent or in a container.
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
[ -n "$LASTIT" ] || err "cannot resolve the last iteration (PR $PRID / $REPO)"
CHANGED=""; skip=0
while :; do # every page; fail closed when a page cannot be read
  page=$(curl -s -f -H "Authorization: Basic $AUTH" "$B/$REPO/pullRequests/$PRID/iterations/$LASTIT/changes?\$top=1000&\$skip=$skip&api-version=7.0") \
    || err "cannot list the changed files (PR $PRID / $REPO)"
  jq -e '.changeEntries | type == "array"' >/dev/null 2>&1 <<<"$page" || err "cannot list the changed files (PR $PRID / $REPO)"
  CHANGED+=$(jq -r '.changeEntries[] | select((.item.isFolder // false) | not) | (.item.path // .originalPath // empty)' <<<"$page")$'\n'
  next=$(jq -r '.nextSkip // 0' <<<"$page"); [ "$next" -gt "$skip" ] 2>/dev/null || break; skip=$next
done
[ -n "${CHANGED//[$'\n']/}" ] || err "no changed files listed (PR $PRID / $REPO)"
BUILD_RE='(^|/)(pom\.xml|mvnw|mvnw\.cmd|settings\.xml|settings-security\.xml|toolchains\.xml)$|(^|/)\.mvn/|META-INF/services/javax\.annotation\.processing\.Processor$'
KNOWN_RE='\.(java|kt|properties|ya?ml|sql|md|txt|csv|png|jpe?g|gif|svg|ico)$'   # never executed by a build
BUILD_FILES=$( { printf '%s\n' "$CHANGED" | grep -E "$BUILD_RE"; printf '%s\n' "$CHANGED" | grep -v '^$' | grep -vE "$KNOWN_RE"; } | sort -u | head -20)
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
PROCS=$(cd "$WD/src" && find . -path '*/src/*' -path '*META-INF/services/javax.annotation.processing.Processor' -not -path './.git/*' 2>/dev/null | sed 's#^\./##' | head -10)
if [ -n "$PROCS" ] && [ "${TC_ALLOW_BUILD_CHANGES:-false}" != true ]; then
  jq -n --arg r "$REPO" --argjson p "$PRID" --arg s "$SRC" --arg f "$PROCS" \
    '{repo:$r,prId:$p,src:$s[0:10],verdict:"in-repo-processor",buildFiles:($f|split("\n"))}'
  exit 0
fi
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
