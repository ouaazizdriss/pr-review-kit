#!/usr/bin/env bash
# deploy.sh — launch the Azure DevOps deployment pipelines of services.
#
#   deploy.sh -e <env> -s svc1,svc2 [-b branch] [--dry-run] [-y] [--wait] [--timeout MIN]
#   deploy.sh -e <env> --all … | deploy.sh --list
#
# The service → pipeline id map is the workspace file pipelines.map ("service=id" per
# line, DEPLOY_PIPELINES_FILE to override). Environments come from DEPLOY_ENVIRONMENTS;
# the pipeline receives the environment as templateParameters.env. The branch defaults
# to the CI_BRANCH variable of the Library variable group mapped to the environment in
# DEPLOY_LIBRARY_GROUPS ("env=group …"). Environments listed in PRODUCTION_ENVS need
# --confirm-production. Before launching, each pipeline must exist and be named after
# its service, and the branch must exist in the service repository.
# Exit: 0 all launched (and succeeded with --wait), 1 a launch or run failed, 2 bad arguments.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
API="$ADO_PROJECT_API"
MAP="${DEPLOY_PIPELINES_FILE:-$PRR_WORKSPACE/pipelines.map}"
ENVS="${DEPLOY_ENVIRONMENTS:-}"
declare -A PIPE=() GROUP=()
if [ -f "$MAP" ]; then
  while IFS='=' read -r k v; do
    k=$(echo "$k" | xargs); v=$(echo "${v%%#*}" | xargs)
    [ -z "$k" ] || [[ "$k" == \#* ]] || [ -z "$v" ] && continue
    PIPE[$k]=$v
  done < "$MAP"
fi
for kv in ${DEPLOY_LIBRARY_GROUPS:-}; do GROUP[${kv%%=*}]=${kv#*=}; done

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }
c() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
api_get() { ado_get "$1"; }

ENV_VALUE="${DEPLOY_DEFAULT_ENV:-}"; BRANCH=""; SERVICES=(); ALL=0; YES=0; DRY=0; WAIT=0; TIMEOUT_MIN=60; CONFIRM_PROD=0
while [ $# -gt 0 ]; do
  case "$1" in
    -e|--env) ENV_VALUE=$2; shift 2 ;;
    -b|--branch) BRANCH=$2; shift 2 ;;
    -s|--services) read -ra _s <<<"${2//,/ }"; SERVICES+=("${_s[@]}"); shift 2 ;;
    -a|--all) ALL=1; shift ;;
    -y|--yes) YES=1; shift ;;
    -n|--dry-run) DRY=1; shift ;;
    -w|--wait) WAIT=1; shift ;;
    --timeout) TIMEOUT_MIN=$2; shift 2 ;;
    --confirm-production) CONFIRM_PROD=1; shift ;;
    -l|--list) for s in $(printf '%s\n' "${!PIPE[@]}" | sort); do printf '%-40s %s\n' "$s" "${PIPE[$s]}"; done; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    -*) c 31 "Unknown option: $1"; usage; exit 2 ;;
    *) read -ra _s <<<"${1//,/ }"; SERVICES+=("${_s[@]}"); shift ;;
  esac
done
[ ${#PIPE[@]} -gt 0 ] || { c 31 "No pipelines: create $MAP (service=pipelineId per line)"; exit 2; }
[ -n "$ENV_VALUE" ] || { c 31 "No environment: use -e (known: ${ENVS:-none configured})"; exit 2; }
if [ -n "$ENVS" ] && ! prr_list_contains "$ENVS" "$ENV_VALUE"; then c 31 "Unknown environment: $ENV_VALUE (known: $ENVS)"; exit 2; fi
if prr_list_contains "${PRODUCTION_ENVS:-production}" "$ENV_VALUE" && [ $CONFIRM_PROD -eq 0 ] && [ $DRY -eq 0 ]; then
  c 31 "$ENV_VALUE is a production environment: add --confirm-production"; exit 2
fi

library_branch() {
  api_get "$API/distributedtask/variablegroups?groupName=$1&api-version=7.1-preview.2" \
    | jq -r --arg g "$1" '[.value[]? | select(.name == $g)][0].variables.CI_BRANCH.value // empty' 2>/dev/null
}
G="${GROUP[$ENV_VALUE]:-}"; LIB_BRANCH=""
[ -n "$G" ] && LIB_BRANCH=$(library_branch "$G")
if [ -z "$BRANCH" ]; then
  if [ -n "$LIB_BRANCH" ]; then BRANCH=$LIB_BRANCH; c 36 "Branch from Library group $G: CI_BRANCH=$LIB_BRANCH"
  else c 31 "No branch: use -b (no CI_BRANCH found for $ENV_VALUE)"; exit 2; fi
fi
BRANCH="refs/heads/${BRANCH#refs/heads/}"
[ -n "$LIB_BRANCH" ] && [ "$BRANCH" != "refs/heads/${LIB_BRANCH#refs/heads/}" ] && c 33 "⚠ -b $BRANCH differs from $G.CI_BRANCH ($LIB_BRANCH)"

[ $ALL -eq 1 ] && mapfile -t SERVICES < <(printf '%s\n' "${!PIPE[@]}" | sort)
[ ${#SERVICES[@]} -gt 0 ] || { c 31 "No service (use -s, --all or --list)"; exit 2; }
mapfile -t SERVICES < <(printf '%s\n' "${SERVICES[@]}" | awk 'NF && !seen[$0]++')
for s in "${SERVICES[@]}"; do [ -n "${PIPE[$s]:-}" ] || { c 31 "Unknown service: $s (see --list)"; exit 2; }; done

check_pipeline() { # svc id → 0 ok (may print a warning), 1 refused
  local name; name=$(api_get "$API/pipelines/$2?api-version=7.1" | jq -r '.name // empty' 2>/dev/null)
  [ -n "$name" ] || { echo "pipeline $2 not found"; return 1; }
  [ "$name" = "$1" ] && return 0
  [[ "$name" =~ ^$1\ \([0-9]+\)$ ]] && { echo "pipeline $2 is named \"$name\" (a CI build pipeline?)"; return 0; }
  echo "pipeline $2 is named \"$name\", not \"$1\""; return 1
}
check_branch() { # svc ref → 0 ok, 1 missing, 2 repo not found
  local res; res=$(api_get "$ADO_REPOS_BASE/$1/refs?filter=heads/${2#refs/heads/}&$V")
  echo "$res" | jq -e '.value' >/dev/null 2>&1 || return 2
  echo "$res" | jq -e --arg r "$2" '[.value[] | select(.name == $r)] | length > 0' >/dev/null 2>&1 && return 0
  return 1
}

c 36 "Environment: $ENV_VALUE · Branch: $BRANCH"
OK=(); errors=0
for s in "${SERVICES[@]}"; do
  id=${PIPE[$s]}
  msg=$(check_pipeline "$s" "$id"); rc=$?
  [ $rc -ne 0 ] && { c 31 "✗ $s: $msg — skipped"; errors=$((errors+1)); continue; }
  [ -n "$msg" ] && c 33 "⚠ $s: $msg"
  check_branch "$s" "$BRANCH"; rc=$?
  [ $rc -eq 1 ] && { c 31 "✗ $s: branch ${BRANCH#refs/heads/} not in the repository — skipped"; errors=$((errors+1)); continue; }
  [ $rc -eq 2 ] && c 33 "⚠ $s: repository \"$s\" not found, branch not checked"
  OK+=("$s")
done
[ ${#OK[@]} -gt 0 ] || { c 31 "Nothing to launch."; exit 1; }
echo "Services to deploy:"; for s in "${OK[@]}"; do echo "  - $s (pipeline ${PIPE[$s]})"; done
[ $DRY -eq 1 ] && { c 33 "Dry run: nothing launched."; [ $errors -eq 0 ]; exit $?; }
if [ $YES -eq 0 ]; then read -r -p "Launch ${#OK[@]} deployment(s) on $ENV_VALUE? [y/N] " a; [[ "$a" =~ ^[yYoO]$ ]] || { echo "Cancelled."; exit 1; }; fi

declare -A RUN=()
for s in "${OK[@]}"; do
  body=$(jq -n --arg b "$BRANCH" --arg e "$ENV_VALUE" '{resources:{repositories:{self:{refName:$b}}}, templateParameters:{env:$e}}')
  resp=$(ado_write POST "$API/pipelines/${PIPE[$s]}/runs?api-version=7.1" "$body")
  run=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)
  if [ -n "$run" ]; then RUN[$s]=$run; c 32 "✓ $s: run $run — https://dev.azure.com/$ADO_ORG/$ADO_PROJECT/_build/results?buildId=$run"
  else c 31 "✗ $s: launch failed — $(echo "$resp" | jq -r '.message // empty' 2>/dev/null | head -c 200)"; errors=$((errors+1)); fi
done

if [ $WAIT -eq 1 ] && [ ${#RUN[@]} -gt 0 ]; then
  c 36 "Waiting for the runs (max $TIMEOUT_MIN min)…"
  deadline=$(( $(date +%s) + TIMEOUT_MIN*60 )); declare -A FINISHED=()
  while [ ${#FINISHED[@]} -lt ${#RUN[@]} ] && [ "$(date +%s)" -lt $deadline ]; do
    for s in "${!RUN[@]}"; do
      [ -n "${FINISHED[$s]:-}" ] && continue
      r=$(api_get "$API/pipelines/${PIPE[$s]}/runs/${RUN[$s]}?api-version=7.1")
      if [ "$(echo "$r" | jq -r '.state // empty')" = completed ]; then
        res=$(echo "$r" | jq -r '.result // empty'); FINISHED[$s]=$res
        if [ "$res" = succeeded ]; then c 32 "✓ $s: run ${RUN[$s]} $res"; else c 31 "✗ $s: run ${RUN[$s]} $res"; errors=$((errors+1)); fi
      fi
    done
    [ ${#FINISHED[@]} -lt ${#RUN[@]} ] && sleep 20
  done
  for s in "${!RUN[@]}"; do [ -z "${FINISHED[$s]:-}" ] && { c 33 "⚠ $s: run ${RUN[$s]} still running after $TIMEOUT_MIN min"; errors=$((errors+1)); }; done
fi
[ $errors -eq 0 ] && { c 32 "All deployments launched successfully."; exit 0; }
c 31 "$errors problem(s) — see above."; exit 1
