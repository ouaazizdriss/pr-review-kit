---
name: setup
description: Create or update a team workspace for pr-review-kit — ask for the Azure DevOps organisation and project, repositories, team group, ticket pattern, Jira, language and repository kinds, then write config.env and repos.allowlist with safe defaults (dry-run, unique marker) and run the doctor. Use when installing the kit for a team or when asked to configure it.
argument-hint: "[workspace directory]"
disable-model-invocation: true
---

# Set up a team workspace

## 1. Workspace folder

Use `$ARGUMENTS` if given, else the configured `${user_config.workspace}` if it is a real path,
else ask (suggest `~/pr-review/<team>`). Then:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init-workspace.sh" "<dir>"
```

It creates `config.env`, `repos.allowlist`, `team-notes.md`, `pipelines.map`,
`jira-workflow.json`, `.claude/settings.json`, `state/` and `reviews/` without overwriting
anything, records the folder in `~/.config/pr-review-kit/workspace`, and writes in
`.claude/settings.local.json` the permission rule that lets the agent run the kit's scripts. The
shared `.claude/settings.json` keeps the agent to those scripts, writes under `reviews/`, `state/`
and `history.md`, and denies `curl`, `wget` and `git push`. Start review sessions from the
workspace folder so these rules apply.

## 2. Ask for the values

Ask in a few grouped questions (offer the detected or default value first):

1. Azure DevOps organisation and project (`https://dev.azure.com/<org>/<project>`).
2. Repositories in scope. If `AZURE_DEVOPS_PAT` is set, first write `ADO_ORG` and `ADO_PROJECT`
   into `<dir>/config.env`, then list them for the person to pick:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ado-get.sh" "git/repositories?api-version=7.0"` (read the
   `name` of each entry).
3. Which of them are migration repositories, shared libraries, front-end portals.
4. Ticket key prefixes (→ `TICKET_KEY_REGEX='(ABC|XYZ)-[0-9]+'`) and Jira base URL + account
   e-mail (or no Jira).
5. Team reviewer group (optional): its id from
   `https://dev.azure.com/<org>/_apis/graph/groups` or from a PR where the group is a reviewer.
6. Review language and policy profile (`standard` recommended for the first weeks).
7. A short team slug for the marker → `PR_MARKER="<!-- pr-review:<slug> -->"`.

## 3. Write the files

Edit `<dir>/config.env` (keep the comments) and `<dir>/repos.allowlist`. Leave
`POST_MODE="dry-run"`. Never write a token into any file: tell the person which environment
variables to export (`AZURE_DEVOPS_PAT`, then optionally `JIRA_PAT`, `GCHAT_WEBHOOK_URL`,
`AZURE_DEVOPS_MERGE_PAT`) and where (shell profile, or a vault for pipelines).

Suggest filling `team-notes.md` with what reviewers of this team must know (contracts, release
model, known false positives).

## 4. Check

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/use-workspace.sh" "<dir>"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh"
```

Explain each ✗ and how to fix it. Finish with the next step: one dry-run review
(`/pr-review-kit:review-pr <repo> <id>`), then `POST_MODE=comment`, then `comment+vote` once the
team owner agrees.
