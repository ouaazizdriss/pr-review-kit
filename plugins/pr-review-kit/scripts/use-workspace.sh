#!/usr/bin/env bash
# use-workspace.sh <dir> — make <dir> the workspace the kit scripts use (writes the pointer
# file ~/.config/pr-review-kit/workspace). The skills call it once instead of prefixing every
# command with PRR_WORKSPACE=…, so permission rules can match the script path exactly.
# A PRR_WORKSPACE set in the environment (CI) still takes precedence over the pointer.
#
# It also writes, in <dir>/.claude/settings.local.json (per machine, not shared), the one
# permission rules that let the agent run the kit: `Bash(bash <this kit's scripts dir>/*)` (and the
# quoted form),
# with the real absolute path of the installed version. Older kit rules are replaced, other
# local settings are kept. Bash permission rules match the command text literally (no ~ or
# $HOME expansion), so this rule cannot live in the shared settings.json.
set -euo pipefail
WS="${1:?usage: use-workspace.sh <dir>}"
case "$WS" in *'${'*) echo "use-workspace: no configured workspace (placeholder) — nothing changed"; exit 0 ;; esac
WS="${WS/#\~/$HOME}"
[ -f "$WS/config.env" ] || { echo "use-workspace: $WS has no config.env — run /pr-review-kit:setup" >&2; exit 2; }
WS="$(cd "$WS" && pwd)"
POINTER="${XDG_CONFIG_HOME:-$HOME/.config}/pr-review-kit/workspace"
mkdir -p "$(dirname "$POINTER")"
[ "$(head -n1 "$POINTER" 2>/dev/null)" = "$WS" ] || echo "$WS" > "$POINTER"
KIT_SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
LOCAL="$WS/.claude/settings.local.json"
mkdir -p "$WS/.claude"
[ -s "$LOCAL" ] || echo '{}' > "$LOCAL"
tmp=$(mktemp)
jq --arg r1 "Bash(bash $KIT_SCRIPTS/*)" --arg r2 "Bash(bash \"$KIT_SCRIPTS/*)" '
  .permissions.allow = ([(.permissions.allow // [])[] | select(test("/pr-review-kit/") | not)] + [$r1, $r2])' "$LOCAL" > "$tmp" \
  && mv "$tmp" "$LOCAL" || { rm -f "$tmp"; echo "use-workspace: cannot update $LOCAL" >&2; exit 2; }
echo "workspace: $WS"
