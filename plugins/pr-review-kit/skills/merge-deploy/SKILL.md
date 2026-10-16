---
name: merge-deploy
description: Merge the approved (+10) pull requests ticket by ticket, carry merged release fixes over to later release branches and the default branch, move Jira tickets, deploy the changed services to a test environment, and write a batch report. Runs only when a person explicitly asks for a merge or deploy batch.
argument-hint: "[TICKETS=ABC-1,ABC-2] [MODE=interactive|autonomous] [SQL_APPLIED=yes|no] [ENV=<environment>]"
disable-model-invocation: true
---

# Merge and deploy batch

Parameters from `$ARGUMENTS` (defaults): `TICKETS=all`, `MODE=interactive`, `SQL_APPLIED=no`,
`ENV=` the configured `DEPLOY_DEFAULT_ENV`.

- `MODE=interactive`: ask the person at every ambiguity (offer your recommendation first).
- `MODE=autonomous`: never guess — set the ticket aside, list it under « To arbitrate », go on.

Every kit command in full:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge/<script>" <args>
```

**Workspace.** The configured workspace is `${user_config.workspace}`. If that is a real path
(not empty, not a literal placeholder), prefix every kit command with `PRR_WORKSPACE="<that path>"`.
Otherwise run the commands as written: the scripts use `$PRR_WORKSPACE` from the environment, or
the folder recorded by setup in `~/.config/pr-review-kit/workspace`.

## 0. Load

`show-config.sh`, then read `policyFiles.merge` (the rules of this skill — follow them exactly),
`teamNotes`, and `<workspace>/jira-workflow.json`. Writes use `AZURE_DEVOPS_MERGE_PAT` when it is
set. Never deploy to an environment listed in `PRODUCTION_ENVS`.

## 1. Find what can be merged

List the active PRs of the project (paginate), keep the non-Draft ones where the reviewer's vote
is +10, filter on `TICKETS`, group by ticket key and attach every active sibling of each ticket.
Check the preconditions of the policy (§1); set aside failing tickets with the reason.

If nothing qualifies, say so in one line and stop.

## 2. Plan and confirm

Show the plan: per ticket, the PRs in merge order, the carry-over chain of each, the services to
deploy. In interactive mode wait for the person's go. Migration PRs need `SQL_APPLIED=yes` or an
explicit go.

## 3. Merge

Per ticket, in order: re-read status and tip, then `merge-pr.sh <repo> <id>` (add `--dry-run`
first if the person asked for a rehearsal). Wait for completion before the next PR. Conflicts →
policy §3.

## 4. Carry over

For each PR merged on a release branch: list the later release branches
(`git ls-remote --heads <repo url> '<RELEASE_BRANCH_PATTERN>'`, semver order) then the default
branch. Use an open twin PR with the same patch if one exists; otherwise
`cherry-pick-pr.sh <repo> <srcPrId> <squashCommit> <target>`. Then `presence.sh <repo> <squash>
<target>` on every target.

## 5. Jira after merge

`merge/jira.sh state <KEY>` first. Apply `afterMerge` from `jira-workflow.json` with
`merge/jira.sh goto`, only from the listed statuses. Create the configured sub-tasks
(`merge/jira.sh create`), after checking the existing ones.

## 6. Deploy

Check that migrations needed before the deployment were applied. Then
`deploy.sh -e <ENV> -s <services> --dry-run`, show the result, then `deploy.sh -e <ENV> -s
<services> -y --wait`. Follow every run to the end.

## 7. Jira after deployment

Only for tickets whose services all deployed successfully and that are still in the after-merge
status: apply `afterDeploy`.

## 8. Report

Write the batch report (policy §6) to `<workspace>/reports/merge-<YYYY-MM-DD>.md` — and as PDF
if the person asks and `google-chrome` is available. Append one entry per ticket to the history
file. Give the person the report path and the « To arbitrate » list.
