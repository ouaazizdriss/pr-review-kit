#!/usr/bin/env bash
# jira.sh — Jira helpers for the merge-deploy module (the ONLY kit script that writes to Jira).
#
#   jira.sh state <KEY>…                     type, status, assignee, sub-tasks, transitions
#   jira.sh status <KEY>                     current status name
#   jira.sh goto <KEY> <target> [via…]       move to <target> by name (or "#<id>" for a
#                                            transition id), walking the via statuses if needed;
#                                            never called for a status the ticket already passed
#   jira.sh create <PARENT> <summary> [accountId]   create a sub-task, prints its key
#   jira.sh owner <KEY>                      assignee accountId
#   jira.sh me                               accountId of JIRA_EMAIL
#
# Needs JIRA_BASE, JIRA_EMAIL (config), JIRA_PAT (environment). Sub-task issue type ids per
# project come from JIRA_SUBTASK_TYPES, e.g. "ABC=10033 XYZ=10770".
set -u
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
prr_load --no-auth
[ -n "${JIRA_BASE:-}" ] || prr_die "JIRA_BASE is not configured"
[ -n "${JIRA_PAT:-}" ] || prr_die "JIRA_PAT is not set"
U="$JIRA_EMAIL:$JIRA_PAT"; A="$JIRA_API"

jget()  { curl -s -m 30 -u "$U" -H "Accept: application/json" "$A/$1"; }
jpost() { curl -s -m 30 -u "$U" -H "Content-Type: application/json" -X POST -d "$2" "$A/$1"; }
norm()  { tr '[:upper:]ÉÈÊÀ' '[:lower:]éèêà' <<<"$1" | sed "s/[éèê]/e/g;s/à/a/g;s/[’']/'/g"; }

status() { jget "issue/$1?fields=status" | jq -r '.fields.status.name'; }
step() { # key target → one transition if available
  local k=$1 t=$2 tid
  if [[ "$t" == \#* ]]; then tid=${t#\#}
  else
    t=$(norm "$t")
    tid=$(jget "issue/$k/transitions" | jq -r '.transitions[] | "\(.id)\t\(.to.name)"' \
          | while IFS=$'\t' read -r i n; do [ "$(norm "$n")" = "$t" ] && { echo "$i"; break; }; done)
  fi
  [ -n "$tid" ] || return 1
  [ "$(curl -s -m 30 -o /dev/null -w '%{http_code}' -u "$U" -H "Content-Type: application/json" -X POST \
        -d "{\"transition\":{\"id\":\"$tid\"}}" "$A/issue/$k/transitions")" = 204 ]
}
goto() { # key target [via…]
  local k=$1 t=$2; shift 2
  [[ "$t" != \#* ]] && [ "$(norm "$(status "$k")")" = "$(norm "$t")" ] && return 0
  step "$k" "$t" && return 0
  local m; for m in "$@"; do step "$k" "$m"; step "$k" "$t" && return 0; done
  return 1
}
create() { # parent summary [assignee]
  local p=$1 proj=${1%%-*} type=""
  local kv; for kv in ${JIRA_SUBTASK_TYPES:-}; do [ "${kv%%=*}" = "$proj" ] && type=${kv#*=}; done
  [ -n "$type" ] || { echo "ERR no sub-task type for $proj in JIRA_SUBTASK_TYPES"; return 1; }
  jpost issue "$(jq -n --arg p "$p" --arg s "$2" --arg a "${3:-}" --arg proj "$proj" --arg t "$type" \
     '{fields:({project:{key:$proj}, parent:{key:$p}, issuetype:{id:$t}, summary:$s} + (if $a == "" then {} else {assignee:{accountId:$a}} end))}')" \
   | jq -r '.key // ("ERR " + (.errors | tostring))'
}
owner() { jget "issue/$1?fields=assignee" | jq -r '.fields.assignee.accountId // ""'; }
me() { jget myself | jq -r '.accountId'; }
state() {
  local k j
  for k in "$@"; do
    j=$(jget "issue/$k?fields=status,issuetype,assignee,subtasks,summary")
    echo "## $k [$(jq -r .fields.issuetype.name <<<"$j")] $(jq -r .fields.status.name <<<"$j") | assignee=$(jq -r '.fields.assignee.displayName // "-"' <<<"$j")"
    jq -r '.fields.subtasks[]? | "   \(.key) \(.fields.summary) — \(.fields.status.name)"' <<<"$j"
    echo "   transitions: $(jget "issue/$k/transitions" | jq -r '[.transitions[] | "\(.id):\(.name)→\(.to.name)"] | join(" | ")')"
  done
}

cmd="${1:-}"; shift || true
case "$cmd" in
  state|status|goto|create|owner|me) "$cmd" "$@" ;;
  *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
