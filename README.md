# PR Review Kit

A Claude Code plugin for reviewing pull requests on Azure DevOps against a written review policy.
It finds the PRs that need attention, reviews each one against its real diff with cross-repository
context, runs merge-conflict, security-scanner and test-compile checks, checks the Jira ticket, and
posts a comment and a strict vote. A separate module merges approved PRs, carries them over to later
branches and deploys them.

Everything specific to a team lives in that team's **workspace** (`config.env`). The kit itself
contains no organisation, project, person or token.

- Plugin reference (skills, scripts, workspace layout): [`plugins/pr-review-kit/README.md`](plugins/pr-review-kit/README.md)
- Review policy: [`plugins/pr-review-kit/policy/`](plugins/pr-review-kit/policy)
- Changes: [`plugins/pr-review-kit/CHANGELOG.md`](plugins/pr-review-kit/CHANGELOG.md)

---

## Requirements

Check them all at once after installing: `/pr-review-kit:doctor`.

### 1. Platform

| Requirement | Why |
|---|---|
| **Linux** (or WSL 2 on Windows) | the scripts use GNU `base64 -w0`, `sed -i`, `flock` and `column` from util-linux. macOS is **not supported** in 1.0 |
| **bash ≥ 4** | associative arrays and `mapfile` |
| **Claude Code** — tested with **2.1.300** | plugins, skills, `${CLAUDE_PLUGIN_ROOT}` and `userConfig` substitution |
| An Anthropic account for Claude Code (or `ANTHROPIC_API_KEY` for scheduled, headless runs) | the reviews are written by Claude |

### 2. Tools

**Required** — the kit does not run without them:

| Tool | Version | Used for |
|---|---|---|
| `curl` | any recent | Azure DevOps, Jira and Chat REST calls |
| `jq` | **≥ 1.6** | every JSON step |
| `git` | **≥ 2.38** | clones for the checks; `git merge-tree --write-tree` for sibling-conflict detection |
| coreutils, util-linux | — | `base64`, `mktemp`, `flock`, `column` |

**Optional** — each one enables one check. When it is missing, that check is skipped and the
review says so. The review never quietly passes a check that did not run:

| Tool | Enables | Note |
|---|---|---|
| `semgrep` | SAST on the PR's changed files (`scan-pr.sh`) | downloads its rules from semgrep.dev (`SEMGREP_CONFIG`, default `p/default`) |
| `trivy` | dependency CVEs, secrets and misconfigurations when dependencies or IaC change | downloads its vulnerability database on first run |
| `mvn` + a JDK | checks that main and test sources compile (`check-test-compile.sh`) | private artefacts must be resolvable through your `~/.m2/settings.xml`, otherwise the result is `env-unverifiable` (reported, not blocking) |
| `python3` | merge module: automatic resolution of import-only conflicts | |
| `whiptail` | interactive menu of `list-prs-by-ticket.sh` | |
| `google-chrome` | PDF batch reports in the merge module | Markdown reports work without it |

### 3. Accounts and access

| What | Required for | Details |
|---|---|---|
| **Azure DevOps token** `AZURE_DEVOPS_PAT` | everything | **Code (Read)** to read PRs, files and clone · **Pull Request Threads (Read & Write)** to comment · votes and adding the reviewer as *required* need the right to contribute to pull requests on the repositories (**Code (Read & Write)**). Use a **dedicated bot account** per team for scheduled runs: Azure DevOps refuses votes by a PR's author, and votes under a person's name read as that person's decision |
| **Merge token** `AZURE_DEVOPS_MERGE_PAT` | merge-deploy module only | Code (Read & Write) to complete PRs and push carry-over branches · Build (Read & Execute) to run deployment pipelines · Variable Groups (Read) for `CI_BRANCH`. Without it the module uses `AZURE_DEVOPS_PAT` |
| **Jira API token** `JIRA_PAT` + `JIRA_EMAIL`/`JIRA_BASE` in config | optional: the ticket line of reviews; the merge module's ticket moves | reviews only **read** Jira. The merge module moves tickets and creates sub-tasks, so the account then needs those rights |
| **Google Chat webhook** `GCHAT_WEBHOOK_URL` | optional: waiting-for-author reminder | one incoming webhook per team space. The URL contains a secret: environment only |
| **Read access to this repository** | installing the plugin | Claude Code clones the marketplace with your **existing git credentials** and does not prompt. Before installing, make `git ls-remote https://github.com/ouaazizdriss/pr-review-kit.git` work, through a credential helper, `gh auth setup-git`, or SSH |

Secrets are read **only from environment variables**. No kit file and no workspace file holds one,
and the scripts never print them.

### 4. Network

Outbound HTTPS to `dev.azure.com`, `github.com` (install and updates), and, when used, your Jira
host (`*.atlassian.net`), `chat.googleapis.com`, `semgrep.dev`, Trivy's database registry
(`ghcr.io` / `mirror.gcr.io`), your Maven repositories, and `api.anthropic.com`.

### 5. A team workspace

A folder per team, created by `/pr-review-kit:setup`. Before the kit runs, `config.env` must define
at least:

| Key | Example |
|---|---|
| `ADO_ORG`, `ADO_PROJECT` | `my-org`, `MyProject` |
| `TICKET_KEY_REGEX` | `'(ABC\|XYZ)-[0-9]+'` |
| `REVIEW_LANGUAGE` | `en`, `fr` |
| `POLICY_PROFILE` | `strict` or `standard` |
| `POST_MODE` | `dry-run` (default), `comment`, `comment+vote` |
| `PR_MARKER` | `<!-- pr-review:myteam -->` — **unique per team**; the generic `<!-- pr-review -->` is refused |

and `repos.allowlist` must list at least one repository. `SQL_REPOS`, `LIBRARY_REPOS` and
`FRONT_REPOS` tell the kit which repositories get the migration rules, no coverage rule, or no
unit-test rule. All other settings are optional and documented in
[`templates/config.env.example`](plugins/pr-review-kit/templates/config.env.example).

### 6. Scheduled runs (optional)

To run the review loop without a person in front of it, see
[`templates/azure-pipelines.review.yml`](plugins/pr-review-kit/templates/azure-pipelines.review.yml).
It needs:
- a pipeline agent with the tools above and Node.js (`npm`) for Claude Code;
- a variable group holding `AZURE_DEVOPS_PAT` (bot account), `ANTHROPIC_API_KEY`, and `GITHUB_PAT`
  (read access to this repository), plus `JIRA_PAT` and `GCHAT_WEBHOOK_URL` when used;
- the team workspace as a git repository, so state and reviews persist between runs.

---

## Install

```text
# 1. in Claude Code — register the marketplace and install the plugin
/plugin marketplace add https://github.com/ouaazizdriss/pr-review-kit.git
/plugin install pr-review-kit@pr-review-tools

# 2. export the secrets in your shell profile (not in any file of the repository)
export AZURE_DEVOPS_PAT=…        # + JIRA_PAT, GCHAT_WEBHOOK_URL, AZURE_DEVOPS_MERGE_PAT as needed

# 3. create the team workspace, then check everything
/pr-review-kit:setup ~/pr-review/myteam
/pr-review-kit:doctor

# 4. first review, in dry-run: nothing is posted, the payload lands in state/outbox/
/pr-review-kit:review-pr <repo> <prId>
```

Shell equivalents: `claude plugin marketplace add <url>` and
`claude plugin install pr-review-kit@pr-review-tools`.

To offer the plugin to everyone opening a team repository, commit this to its `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "pr-review-tools": { "source": { "source": "git", "url": "https://github.com/ouaazizdriss/pr-review-kit.git" } }
  },
  "enabledPlugins": { "pr-review-kit@pr-review-tools": true }
}
```

## Roll-out in a team

1. **dry-run** for about a week: read the review files and `state/outbox/`, note every contested point.
2. `POST_MODE=comment` for a week: comments are posted, votes are not.
3. `POST_MODE=comment+vote` once the team owner agrees.

Start new teams on `POLICY_PROFILE=standard` and move to `strict` once the false-positive rate is
known.

## Updating

Installed copies update **only when the `version` in `plugins/pr-review-kit/.claude-plugin/plugin.json`
changes**. Commits without a version bump do not reach users. Bump it in every release
(patch: fixes, minor: new checks or settings, major: vote-rule changes), tag `vX.Y.Z`, and update the
changelog. Users run `/plugin` → update, or `claude plugin update pr-review-kit@pr-review-tools`.

## Developing

```bash
bats plugins/pr-review-kit/tests                # 23 tests, fake curl, no network
shellcheck -x -S warning plugins/pr-review-kit/scripts/*.sh plugins/pr-review-kit/scripts/*/*.sh
claude plugin validate --strict plugins/pr-review-kit && claude plugin validate --strict .
claude --plugin-dir plugins/pr-review-kit       # try local changes without installing
```

CI (`.github/workflows/ci.yml`) runs the same checks on every push.

## Known limits (1.0.3)

- Linux and WSL only.
- Azure DevOps and Jira Cloud only.
- Headless runs were tested with `--plugin-dir`. Installing from the private marketplace on a CI
  runner depends on the git credential set up there: test it once on your runner.
- Start review sessions from the workspace folder: the permission rules in its `.claude/settings.json`
  (kit scripts only, no `curl`/`wget`/`git`/`jq`/`env`, writes under `reviews/`, `state/`, `history.md`)
  apply only there. Run `use-workspace.sh` (the skills do it) after each kit upgrade.
- `check-test-compile.sh` compiles code written by the PR author on your machine. It refuses PRs
  that change the build or touch files a build may execute, and repositories with their own
  annotation processor, and strips secrets from mvn's environment — but it is not a sandbox (a
  plugin already in the pom may run project code): for untrusted contributors, run the kit on a
  throwaway agent.
- `merge-pr.sh` merges only a +10 cast through `post.sh` **on the same machine** (protected ledger
  in `~/.local/state/pr-review-kit/`). Votes cast in CI or by hand need a person to pass
  `--expect-tip <reviewed commit>` from a terminal.
- The kit relies on your Azure DevOps branch policies for anything it does not check itself, for
  example a "reset votes on push" policy. Read the live vote; never assume a past vote still holds.
