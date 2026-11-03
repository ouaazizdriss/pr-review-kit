#!/usr/bin/env bash
# list-branches.sh <repo> [glob] — branch names of a repository, through the Azure DevOps refs
# API (read-only). Default glob: RELEASE_BRANCH_PATTERN (release/*). Release-like names are
# sorted in version order. Replaces `git ls-remote` for the agent: a git command line accepts
# options such as --upload-pack that run arbitrary programs, so the skills never get git.
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
prr_load
REPO="${1:?usage: list-branches.sh <repo> [glob]}"
case "$REPO" in *[!A-Za-z0-9._-]*) prr_die "invalid repository name: $REPO" ;; esac
GLOB="${2:-${RELEASE_BRANCH_PATTERN:-release/*}}"
REFS=$(prr_get "$ADO_REPOS_BASE/$REPO/refs?filter=heads/&\$top=5000&api-version=$ADO_API_VERSION") || exit 1
jq -r '.value[]?.name | sub("^refs/heads/"; "")' <<<"$REFS" | while IFS= read -r b; do
  # shellcheck disable=SC2053  # glob match on purpose
  [[ "$b" == $GLOB ]] && printf '%s\n' "$b"
done | sort -V
