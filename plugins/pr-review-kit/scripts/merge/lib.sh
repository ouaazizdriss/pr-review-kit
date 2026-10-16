#!/usr/bin/env bash
# merge/lib.sh — shared setup for the merge-deploy scripts. Source it.
# Reads use the review identity (AZURE_DEVOPS_PAT) so "my vote" means the reviewer's
# vote; writes (complete, push, create PR, run pipelines) use AZURE_DEVOPS_MERGE_PAT
# when set, so the review token can stay read + comment + vote only.
# shellcheck disable=SC2034
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
prr_load
ME=$(prr_reviewer_id)
READ_AUTH="$AUTH"
WRITE_AUTH=$(printf ":%s" "${AZURE_DEVOPS_MERGE_PAT:-$AZURE_DEVOPS_PAT}" | base64 -w0)
V="api-version=$ADO_API_VERSION"
CLONES_DIR="${CLONES_DIR:-$STATE_DIR/clones}"
mkdir -p "$CLONES_DIR"

ado_get()   { curl -s -m 60 -H "Authorization: Basic $READ_AUTH" "$1"; }
ado_write() { # method url body
  curl -s -m 60 -X "$1" -H "Authorization: Basic $WRITE_AUTH" -H "Content-Type: application/json" -d "$3" "$2"
}
git_auth() { git -c http.extraHeader="Authorization: Basic $WRITE_AUTH" "$@"; }

# ensure_clone <repo> — partial clone (no blobs) under $CLONES_DIR, rerere off; echoes the path.
ensure_clone() {
  local d="$CLONES_DIR/$1"
  if [ ! -d "$d/.git" ]; then
    git_auth clone -q --filter=blob:none "$ADO_GIT_WEB/$1" "$d" >/dev/null 2>&1 || return 1
  fi
  git -C "$d" config rerere.enabled false
  git_auth -C "$d" fetch -q origin >/dev/null 2>&1 || return 1
  echo "$d"
}
