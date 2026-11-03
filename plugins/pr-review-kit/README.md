# pr-review-kit — plugin reference

How to use the plugin once it is installed. Requirements and installation are in the
[repository README](../../README.md).

## Skills

| Command | What it does | Writes to Azure DevOps |
|---|---|---|
| `/pr-review-kit:setup [dir]` | creates the team workspace, asks for the settings, runs the doctor | no |
| `/pr-review-kit:doctor` | checks tools, configuration, tokens, access | no |
| `/pr-review-kit:review-pr <repo> <id>` | reviews one PR end to end | per `POST_MODE` |
| `/pr-review-kit:review-loop [--dry-run]` | one pass: scan, detect candidates, review them, re-balance ticket-linked votes | per `POST_MODE` |
| `/pr-review-kit:wfa-reminder [--dry-run]` | posts the waiting-for-author card to Google Chat | no |
| `/pr-review-kit:merge-deploy [TICKETS=…] [MODE=…] [SQL_APPLIED=…] [ENV=…]` | merges approved PRs, carries them over, moves tickets, deploys, reports | yes — only when you run it |

`setup` and `merge-deploy` run only when you type them. The others can also be picked by Claude
when your request matches.

## Workspace

One folder per team, created by `setup` (or `scripts/init-workspace.sh <dir>`):

```
<workspace>/
├── config.env           every team setting (no secrets) — see templates/config.env.example
├── repos.allowlist      repositories in scope
├── team-notes.md        what reviewers of this team must know; read before every review
├── pipelines.map        merge-deploy: service=pipelineId
├── jira-workflow.json   merge-deploy: ticket moves and sub-tasks
├── .claude/settings.json  shared tool permissions: kit scripts only, writes under reviews/ state/
│                        history.md, no curl / wget / git push
├── .claude/settings.local.json  per machine, written by use-workspace.sh: the rule that allows
│                        this machine's installed kit scripts (do not commit)
├── reviews/<TICKET>/<date>/review1-PR-<id>.md
├── history.md           one line per review
└── state/
    ├── state.jsonl      last scan
    ├── votes.jsonl      every vote cast, with the commit it judged
    ├── considered.json  peer comments already read
    └── outbox/          what would have been posted, in dry-run
```

The scripts find the workspace through `$PRR_WORKSPACE`, then `~/.config/pr-review-kit/workspace`.

## Posting modes

| `POST_MODE` | Comments | Votes |
|---|---|---|
| `dry-run` (default) | written to `state/outbox/` | written to `state/outbox/` |
| `comment` | posted | written to `state/outbox/` |
| `comment+vote` | posted | posted |

`PRR_POST_MODE=dry-run` in the environment forces a dry run whatever the config says.

## Scripts

All under `scripts/`, runnable by hand (`bash scripts/<name>.sh`). Read-only unless stated.

| Script | Purpose |
|---|---|
| `show-config.sh` | effective configuration as JSON (no secrets) |
| `doctor.sh` | environment checks |
| `init-workspace.sh <dir>` | create a workspace from the templates |
| `use-workspace.sh <dir>` | select the workspace and refresh this machine's kit permission rule |
| `ado-get.sh <path\|url> [--text]` | read-only GET, limited to the configured organisation |
| `pr-file-diff.sh <repo> <id> [--list\|<path>…]` | the PR's real diff, merge base → tip |
| `scan.sh` | active PRs of the allow-listed repos → `state/state.jsonl` |
| `filter.sh [--json]` | candidates and their reasons |
| `post.sh thread\|reply\|vote\|add-required\|reopen …` | **the only write path** for comments and votes, with every guard |
| `check-merge.sh <repo> <id>` | target conflict, sibling conflicts, semantic risk |
| `scan-pr.sh <repo> <id>` | Semgrep + Trivy on the PR's changes |
| `check-test-compile.sh <repo> <id>` | `mvn test-compile` at the source (and base) commit, empty environment; PRs that change the build itself are not built |
| `jira-issue.sh <KEY>` | ticket existence, type, status |
| `wfa-reminder.sh [--dry-run]` | waiting-for-author card (writes to the Chat webhook only) |
| `list-prs-by-ticket.sh` | PRs grouped by ticket (interactive with whiptail) |
| `check-pr-deployed.sh <tickets> [release-ref]` | are a ticket's PRs in a release? |
| `protect-branch.sh` | audit / apply branch policies (`--apply` writes) |
| `merge/merge-pr.sh` | squash-merge an approved PR, only at the approved commit (writes) |
| `merge/cherry-pick-pr.sh` | one-commit carry-over to another branch (writes) |
| `merge/presence.sh` | is a change already on a branch? |
| `merge/jira.sh` | ticket state, moves, sub-tasks (writes to Jira) |
| `merge/deploy.sh` | launch deployment pipelines (writes) |
| `merge/resolve-imports.py` | resolve import-only conflict hunks |

## Policy

`policy/core-rules.md` (P1–P13 and the hard rules), `policy/review-checklist.md`,
`policy/sql-migrations.md`, `policy/merge-release.md`, `policy/profiles/{strict,standard}.md`.
Changing a rule means a new kit version (see `CHANGELOG.md`).

## Tests

```bash
bats plugins/pr-review-kit/tests      # uses a fake curl: no network, no token needed
```
