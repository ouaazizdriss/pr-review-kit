#!/usr/bin/env bash
# presence.sh <repo> <commit> <targetBranch> — is a change already on a branch?
#   PRESENT(empty)  a dry cherry-pick of the commit onto the target changes nothing
#   PRESENT(lines)  every added line of the commit exists in the target files
#   PRESENT(files)  every touched file is identical on the target
#   ABSENT(...)     with counts of missing lines, deleted files still there, differing files
# "ABSENT" can also mean the change was later replaced by a rewrite — investigate before acting.
set -u
. "$(dirname "$0")/lib.sh"
d=$(ensure_clone "${1:?usage: presence.sh <repo> <commit> <target>}") || { echo "ERROR clone"; exit 1; }
c="${2:?usage}"; T="${3:?usage}"
cd "$d" || exit 1
git checkout -q -f --detach "origin/$T" 2>/dev/null || { echo "ERROR checkout (transient — retry)"; exit 1; }
if out=$(git -c user.name=x -c user.email=x cherry-pick "$c" 2>&1); then
  [ "$(git rev-parse "HEAD^{tree}")" = "$(git rev-parse "origin/$T^{tree}")" ] && { echo "PRESENT(empty)"; git checkout -q -f --detach "origin/$T"; exit 0; }
else
  grep -q empty <<<"$out" && { git cherry-pick --abort 2>/dev/null; echo "PRESENT(empty)"; exit 0; }
  git cherry-pick --abort 2>/dev/null
fi
git checkout -q -f --detach "origin/$T"
miss=0; tot=0
for f in $(git show --name-only --diff-filter=AM --format= "$c"); do
  while IFS= read -r l; do
    tot=$((tot+1)); git show "origin/$T:$f" 2>/dev/null | grep -qxF -- "$l" || miss=$((miss+1))
  done < <(git show --format= "$c" -- "$f" | grep '^+' | grep -v '^+++' | sed 's/^+//' | grep -v '^\s*$')
done
dels=0
for f in $(git show --name-only --diff-filter=D --format= "$c"); do git cat-file -e "origin/$T:$f" 2>/dev/null && dels=$((dels+1)); done
[ "$miss" = 0 ] && [ "$dels" = 0 ] && { echo "PRESENT(lines)"; exit 0; }
diff=0
for f in $(git show --name-only --format= "$c"); do
  a=$(git rev-parse -q --verify "$c:$f" 2>/dev/null); b=$(git rev-parse -q --verify "origin/$T:$f" 2>/dev/null)
  [ "$a" != "$b" ] && diff=$((diff+1))
done
[ "$diff" = 0 ] && { echo "PRESENT(files)"; exit 0; }
echo "ABSENT(missing lines $miss/$tot, deleted files still present $dels, differing files $diff)"
