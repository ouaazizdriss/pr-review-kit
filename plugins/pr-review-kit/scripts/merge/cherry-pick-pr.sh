#!/usr/bin/env bash
# cherry-pick-pr.sh <repo> <srcPrId> <squashCommit> <targetBranch>
#   → "OK #<newPr> <commit>" | "EMPTY" (change already on the target) | "FAIL <reason>"
#
# Carries a merged PR to a later branch as ONE commit: branch cherry-pick/PR-<id>-<target>
# from the target, cherry-pick -x, push, open a PR, wait for the merge evaluation, and
# complete it (squash, delete the branch). Conflicts: an executable resolver
# $STATE_DIR/resolvers/resolve-<srcPrId>.sh is run if present; otherwise the
# cherry-pick is aborted and the conflicting files are listed. Never force-pushes an
# existing branch of someone else: the cherry-pick branch is created by this script.
set -u
. "$(dirname "$0")/lib.sh"
r="${1:?usage}"; src="${2:?usage}"; c="${3:?usage}"; T="${4:?usage: cherry-pick-pr.sh <repo> <srcPrId> <squash> <target>}"
TS=${T//\//-}
NAME="${GIT_AUTHOR_NAME:-$(git config user.name)}"; MAIL="${GIT_AUTHOR_EMAIL:-$(git config user.email)}"
[ -n "$NAME" ] && [ -n "$MAIL" ] || { echo "FAIL set GIT_AUTHOR_NAME and GIT_AUTHOR_EMAIL (or git config user.name/user.email)"; exit 1; }
G=(git -c user.name="$NAME" -c user.email="$MAIL")
d=$(ensure_clone "$r") || { echo "FAIL clone of $r"; exit 1; }
cd "$d" || exit 1
B="$ADO_REPOS_BASE/$r/pullRequests"
title=$(ado_get "$B/$src?$V" | jq -r .title)
br="cherry-pick/PR-$src-$TS"
LBL="${CHERRY_PICK_LABEL:-cherry-pick of !%s to %s}"
# shellcheck disable=SC2059
suffix=$(printf "$LBL" "$src" "$T")

git checkout -q -f -B "$br" "origin/$T" || { echo "FAIL target $T not found"; exit 1; }
if ! out=$("${G[@]}" cherry-pick -x "$c" 2>&1); then
  if grep -q empty <<<"$out"; then git cherry-pick --abort 2>/dev/null; echo "EMPTY"; exit 0; fi
  resolver="$STATE_DIR/resolvers/resolve-$src.sh"
  if [ -x "$resolver" ] && "$resolver" && [ -z "$(git diff --name-only --diff-filter=U)" ]; then
    GIT_EDITOR=true "${G[@]}" cherry-pick --continue >/dev/null || { echo "FAIL continue"; exit 1; }
  else
    files=$(git diff --name-only --diff-filter=U | tr '\n' ' '); git cherry-pick --abort; echo "FAIL conflict: $files"; exit 1
  fi
fi
[ "$(git rev-list --count "origin/$T"..HEAD)" = 1 ] || { echo "FAIL not a single commit"; exit 1; }
msg=("-m" "$title ($suffix)" "-m" "(cherry picked from commit $c)")
[ -n "${MERGE_COMMIT_TRAILER:-}" ] && msg+=("-m" "$MERGE_COMMIT_TRAILER")
"${G[@]}" commit -q --amend "${msg[@]}"
git_auth push -q -f origin "$br" 2>/dev/null || { echo "FAIL push"; exit 1; }

desc="One-commit cherry-pick of PR !$src (squash commit $c) to $T."
new=$(ado_write POST "$B?$V" "$(jq -n --arg s "refs/heads/$br" --arg t "$title ($suffix)" --arg d "$desc" --arg tg "$T" \
  '{sourceRefName:$s, targetRefName:("refs/heads/"+$tg), title:$t, description:$d}')" | jq -r '.pullRequestId // .message')
[[ "$new" =~ ^[0-9]+$ ]] || { echo "FAIL create PR: $new"; exit 1; }

ms=notSet
for _ in $(seq 1 12); do sleep 5; j=$(ado_get "$B/$new?$V"); ms=$(jq -r .mergeStatus <<<"$j"); [ "$ms" != queued ] && [ "$ms" != notSet ] && break; done
[ "$ms" = succeeded ] || { echo "FAIL #$new mergeStatus=$ms"; exit 1; }
tip=$(jq -r .lastMergeSourceCommit.commitId <<<"$j")
ado_write PATCH "$B/$new?$V" "$(jq -n --arg c "$tip" --arg m "Merged PR $new: $title ($suffix)" --argjson bp "${MERGE_ALLOW_BYPASS:-false}" \
  --arg why "${MERGE_BYPASS_REASON:-Carry-over of an approved PR}" \
  '{status:"completed", lastMergeSourceCommit:{commitId:$c},
    completionOptions:({mergeStrategy:"squash", deleteSourceBranch:true, mergeCommitMessage:$m, transitionWorkItems:false}
      + (if $bp then {bypassPolicy:true, bypassReason:$why} else {} end))}')" >/dev/null
for _ in $(seq 1 12); do sleep 5; j=$(ado_get "$B/$new?$V"); [ "$(jq -r .status <<<"$j")" = completed ] && break; done
if [ "$(jq -r .status <<<"$j")" = completed ]; then echo "OK #$new $(jq -r .lastMergeCommit.commitId <<<"$j")"
else echo "FAIL #$new not completed ($(jq -r '.mergeStatus' <<<"$j")) — complete it by hand or set MERGE_ALLOW_BYPASS"; exit 1; fi
