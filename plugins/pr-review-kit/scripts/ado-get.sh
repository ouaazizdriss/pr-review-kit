#!/usr/bin/env bash
# ado-get.sh <api-path | url> [--text] — read-only GET against the team's Azure DevOps.
#
# The review skills use this instead of curl, so the agent never needs a general network
# tool. Only GET; only https://dev.azure.com/<ADO_ORG>/… (the organisation in config.env);
# no redirects followed. A relative path is resolved against the project API
# (https://dev.azure.com/<org>/<project>/_apis/), e.g.
#   ado-get.sh "git/repositories/svc-a/pullRequests/101?api-version=7.0"
# Prints the body. JSON is required unless --text (file contents with $format=text).
# Never prints the token.
set -uo pipefail
. "$(dirname "$0")/lib/common.sh"
prr_load
TARGET="${1:?usage: ado-get.sh <api-path | url> [--text]}"
TEXT=0; [ "${2:-}" = "--text" ] && TEXT=1
case "$TARGET" in
  https://*) URL="$TARGET" ;;
  http://*|//*|*://*) prr_die "only https://dev.azure.com/${ADO_ORG}/ URLs are allowed" ;;
  *) URL="${ADO_PROJECT_API}/${TARGET#/}" ;;
esac
case "$URL" in
  "https://dev.azure.com/${ADO_ORG}/"*) ;;
  *) prr_die "only https://dev.azure.com/${ADO_ORG}/ URLs are allowed" ;;
esac
case "$URL" in *[[:space:]]*|*@*) prr_die "invalid characters in URL" ;; esac
if [ "$TEXT" = 1 ]; then
  out=$(prr_curl -f "$URL") || prr_die "GET failed: ${URL%%\?*}"
  printf '%s\n' "$out"
else
  prr_get "$URL" || exit 1
fi
