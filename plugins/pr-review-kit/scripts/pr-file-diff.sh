#!/usr/bin/env bash
# pr-file-diff.sh <repo> <prId> [--list | <path>…] — the real diff of a PR: merge base → tip.
#
# Uses the last iteration WITHOUT $compareTo (what the PR introduces as a whole), fetches each
# changed file at the merge base and at the tip and prints `diff -u` per file. With --list,
# prints the changed files only (changeType<TAB>path) and the two commits. With paths, limits
# the diff to them. Read-only. Files above PRR_DIFF_MAX_BYTES (default 400000) are listed, not
# diffed. Output starts with "# base <sha> tip <sha>".
set -uo pipefail
. "$(dirname "$0")/lib/common.sh"
prr_load
REPO="${1:?usage: pr-file-diff.sh <repo> <prId> [--list | <path>…]}"
PRID="${2:?usage: pr-file-diff.sh <repo> <prId> [--list | <path>…]}"
shift 2
case "$REPO" in *[!A-Za-z0-9._-]*) prr_die "invalid repository name: $REPO" ;; esac
case "$PRID" in *[!0-9]*) prr_die "invalid PR id: $PRID" ;; esac
B="$ADO_REPOS_BASE/$REPO/pullRequests/$PRID"
MAX="${PRR_DIFF_MAX_BYTES:-400000}"

IT=$(prr_get "$B/iterations?api-version=$ADO_API_VERSION") || exit 1
LAST=$(jq -r '.value | last | .id // empty' <<<"$IT")
TIP=$(jq -r '.value | last | .sourceRefCommit.commitId // empty' <<<"$IT")
BASE=$(jq -r '.value | last | .commonRefCommit.commitId // empty' <<<"$IT")
[ -n "$LAST" ] && [ -n "$TIP" ] && [ -n "$BASE" ] || prr_die "cannot resolve base/tip of PR $PRID"
CH=$(prr_get "$B/iterations/$LAST/changes?api-version=$ADO_API_VERSION&\$top=2000") || exit 1
echo "# base $BASE tip $TIP"
FILES=$(jq -r '.changeEntries[]? | select((.item.isFolder // false) | not)
  | [.changeType, (.item.path // .originalPath // "")] | @tsv' <<<"$CH")
if [ "${1:-}" = "--list" ]; then printf '%s\n' "$FILES"; exit 0; fi

WD=$(mktemp -d "${TMPDIR:-/tmp}/prdiff.XXXXXX"); trap 'rm -rf "$WD"' EXIT
fetch() { # commit path → file (empty when absent)
  local enc; enc=$(jq -rn --arg p "$2" '$p|@uri')
  prr_curl -f -o "$3" "$ADO_REPOS_BASE/$REPO/items?path=$enc&versionDescriptor.version=$1&versionDescriptor.versionType=commit&includeContent=true&\$format=text&api-version=$ADO_API_VERSION" 2>/dev/null || : > "$3"
}
while IFS=$'\t' read -r type path; do
  [ -n "$path" ] || continue
  if [ $# -gt 0 ]; then keep=0; for p in "$@"; do [ "$p" = "$path" ] || [ "/$p" = "$path" ] && keep=1; done; [ $keep = 1 ] || continue; fi
  fetch "$BASE" "$path" "$WD/a"; fetch "$TIP" "$path" "$WD/b"
  if [ "$(stat -c %s "$WD/a")" -gt "$MAX" ] || [ "$(stat -c %s "$WD/b")" -gt "$MAX" ]; then
    echo "# $type $path — too large, not diffed"; continue
  fi
  diff -u --label "a$path" --label "b$path" "$WD/a" "$WD/b"
  [ $? -le 1 ] || echo "# $type $path — binary or unreadable"
done <<<"$FILES"
exit 0
