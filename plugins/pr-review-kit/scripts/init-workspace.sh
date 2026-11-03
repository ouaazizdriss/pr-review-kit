#!/usr/bin/env bash
# init-workspace.sh <dir> [--no-pointer] — create a team workspace from the templates.
#
# Creates <dir>/{config.env, repos.allowlist, team-notes.md, state/, reviews/} without
# overwriting existing files, then records <dir> in ~/.config/pr-review-kit/workspace
# so the scripts find it without PRR_WORKSPACE (skip with --no-pointer).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
TPL="$DIR/../templates"
WS="${1:?usage: init-workspace.sh <dir> [--no-pointer]}"
WS="${WS/#\~/$HOME}"
mkdir -p "$WS/state" "$WS/reviews"
WS="$(cd "$WS" && pwd)"

copy() { # template → target, never overwrite
  if [ -e "$WS/$2" ]; then echo "kept     $2 (already exists)"
  else mkdir -p "$(dirname "$WS/$2")"; cp "$TPL/$1" "$WS/$2"; echo "created  $2"; fi
}
copy config.env.example config.env
copy repos.allowlist.example repos.allowlist
copy team-notes.example.md team-notes.md
copy pipelines.map.example pipelines.map
copy jira-workflow.example.json jira-workflow.json
copy workspace-settings.json .claude/settings.json
[ -e "$WS/state/considered.json" ] || { echo '[]' > "$WS/state/considered.json"; echo "created  state/considered.json"; }

if [ "${2:-}" != "--no-pointer" ]; then
  POINTER="${XDG_CONFIG_HOME:-$HOME/.config}/pr-review-kit/workspace"
  mkdir -p "$(dirname "$POINTER")"
  echo "$WS" > "$POINTER"
  echo "pointer  $POINTER → $WS"
  bash "$DIR/use-workspace.sh" "$WS" >/dev/null && echo "created  .claude/settings.local.json (kit permission rule)"
fi
echo "workspace ready: $WS"
