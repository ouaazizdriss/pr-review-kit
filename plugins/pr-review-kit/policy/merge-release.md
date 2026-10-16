# Merge, carry-over and deployment rules (policy v1.0.0)

Used only by the `merge-deploy` skill, which runs only when a person asks for it.

## Guard rails

- Never production (`PRODUCTION_ENVS`). Never a Draft. Never −10. Never rewrite history of a
  branch you did not create (no force-push of an author's branch). Never move a ticket backwards.
- Ambiguity → ask the person (interactive mode) or set the ticket aside and list it under « To
  arbitrate » (autonomous mode). Never guess.

## 1. What can be merged

- Active non-Draft PRs where the reviewer's vote is **+10**, grouped by ticket, with **all** active
  sibling PRs of the ticket attached (every repository, every branch).
- Per PR, live: vote still +10; no push after the last review (compare the tip with the tip of the
  last cast vote in `state/votes.jsonl`); no active thread from another person; not Draft.
- One sibling at −5 or not reviewed yet → the whole ticket is set aside.

## 2. Order

- Within a ticket: migrations → shared libraries → back-end → front-end, waiting for each merge to
  complete before the next.
- Migration PRs: ask before merging unless the person said the scripts were already applied.

## 3. Conflicts

- Conflict with the target: merge the target **into** the PR branch (no history rewrite), resolve,
  push, re-vote +10 if the push reset votes, then merge.
- Manifests: keep the target's lines, append the PR's block at the end; renumber only when the
  procedure requires it, then run the lint and compare its error count with the target's.
- Import-only conflicts: `merge/resolve-imports.py`. Logic conflicts (two PRs change the same
  behaviour): propose the resolution and wait for approval; compile and run the targeted tests
  before pushing.
- A branch stacked on a squash-merged branch: the true merge base is the pre-squash commit
  (`git merge-tree --write-tree --merge-base=<commit of the first PR> HEAD origin/<target>`);
  verify with patch ids.

## 4. Carry-overs

- A PR merged on a release branch is carried over, as **one** cherry-picked commit, to every
  **later** release branch matching `RELEASE_BRANCH_PATTERN` (semver order, ignore non-semver
  names), then to `DEFAULT_BRANCH`. An open twin PR with the same patch counts as the carry-over.
- `merge/cherry-pick-pr.sh` answers `OK #new`, `EMPTY` (already present — no carry-over needed) or
  `FAIL` (→ §3).
- Libraries published under one shared version by several branches: carry over to every branch in
  the same batch and do the default branch **last** (the last build publishes the artefact).
- Final check on each target: `merge/presence.sh` → `PRESENT(empty|lines|files)` expected. `ABSENT`
  may mean a later rewrite replaced the change: investigate before reporting it.
- Migration repositories whose delivery line is a folder merge everything on the default branch:
  no carry-over.

## 5. Tickets and deployment

- After merge, move tickets per `jira-workflow.json` (`afterMerge`), only from the listed statuses.
- Create the configured sub-tasks only after listing the existing ones (no duplicates); skip the
  projects listed in `skipProjects`.
- Deploy with `merge/deploy.sh -e <env> -s <services> --dry-run`, then `-y --wait`. Services =
  deployable repositories changed by the batch (not migrations, not libraries). Check first that
  migrations needed before the deployment were applied.
- After a successful deployment of **all** a ticket's services, move it per `afterDeploy`.

## 6. Report

One report per batch: per ticket × branch the PR, squash commit, links; conflicts and how they
were solved; carry-over checks; migrations; deployed services with run ids and results; ticket
statuses before and after; tickets set aside and « To arbitrate ». Append one entry to the history
file.
