---
name: doctor
description: Check that pr-review-kit can run — required and optional tools, the team workspace and config.env, the Azure DevOps token and repository access, git over HTTPS, Jira authentication, the Chat webhook. Use when the kit fails, after installing it, or when asked whether the setup is correct.
---

# Doctor

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh"
```

**Workspace.** The configured workspace is `${user_config.workspace}`. If that is a real path
(not empty, not a literal placeholder), prefix every kit command with `PRR_WORKSPACE="<that path>"`.
Otherwise run the commands as written: the scripts use `$PRR_WORKSPACE` from the environment, or
the folder recorded by setup in `~/.config/pr-review-kit/workspace`.

Report the result. For every ✗, give the fix:

| Failure | Fix |
|---|---|
| tool missing | install it (`jq`, `git` ≥ 2.38, `curl`, `flock`/`column` from util-linux) |
| no workspace / config not found | run `/pr-review-kit:setup` |
| PR_MARKER generic | set a team-unique marker, e.g. `<!-- pr-review:myteam -->` |
| AZURE_DEVOPS_PAT not set / rejected | export a valid token for the organisation (scopes in `config.env`) |
| repository HTTP 404 / 401 | wrong name in `repos.allowlist`, or the token has no access |
| git ls-remote failed | the token needs Code (Read) |
| Jira authentication failed | `JIRA_EMAIL` must be the account that owns `JIRA_PAT` |

Optional tools (⚠) only disable their own check. Never print or ask the person to paste a token
in the conversation.
