---
name: review-loop
description: Run one pass of the team's PR review loop on Azure DevOps — scan the active PRs of the allow-listed repositories, detect the ones needing attention (new, pushed, published from Draft, replied to, owner decision, conflict, team-assigned, vote reset, no ticket), review each candidate with the review-pr procedure, then re-balance ticket-linked votes. Use when asked to "run the review loop", "do a review pass", or on a schedule.
argument-hint: "[--dry-run]"
---

# One pass of the review loop

Every kit command is written in full (shell state does not persist):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/<script>.sh" <args>
```

**Workspace.** The configured workspace is `${user_config.workspace}`. If that is a real path
(not empty, not a literal placeholder), prefix every kit command with `PRR_WORKSPACE="<that path>"`.
Otherwise run the commands as written: the scripts use `$PRR_WORKSPACE` from the environment, or
the folder recorded by setup in `~/.config/pr-review-kit/workspace`.

If `$ARGUMENTS` contains `--dry-run`, treat the pass as dry-run whatever `POST_MODE` says: write
the review files and report, but do not run `post.sh`.

## 1. Configuration

Run `show-config.sh`. Stop with a clear message if it fails (no workspace, missing token).
Read `policyFiles.core` once; the per-PR review reads the rest.

## 2. Scan and filter

```bash
… scan.sh
… filter.sh --json
```

Each line is a candidate with its `reasons`. Nothing → report « board up to date » in one line
and stop. Skip `excluded` PRs (already filtered).

## 3. Cheap cases first (no full review)

| Reason alone | Action |
|---|---|
| `team` | `post.sh add-required <repo> <id>` — the PR is then reviewed like any other if it has another reason or was never reviewed |
| `reset` (vote reset with the tip unchanged) | the code is the same: re-cast the last vote (`lastCast.vote`) with a one-line marked reply « vote reset by the platform, code unchanged, verdict maintained » |
| `draft2active` with no push since the Draft review | cast the vote the Draft review merits (re-read the review file to get it) |
| `owner` | read the owner's comment and apply the decision (lift the point, re-vote, restore siblings), then reply with a marked comment |
| `conflict` | short re-check: if the target conflict is real, post a 🟠 « Merge conflict » reply and vote −5 |

## 4. Review the candidates

Group the remaining candidates by ticket key; PRs of one ticket (and branch variants of one
change) are reviewed together so the verdicts stay consistent.

- `loop.parallelAgents` = 1 → review each PR yourself, one after another, following the
  `review-pr` skill (read `${CLAUDE_PLUGIN_ROOT}/skills/review-pr/SKILL.md` and apply it with
  `<repo> <id>` and the reasons as context).
- `loop.parallelAgents` > 1 → start up to that many review agents at once, one per ticket group
  (model `loop.agentModel` when set). Give each agent: the repo and PR ids, the reasons, the
  previous vote, the team thread id, and the instruction to follow
  `${CLAUDE_PLUGIN_ROOT}/skills/review-pr/SKILL.md` without starting agents of its own and without
  posting on any PR outside its group.

## 5. Ticket-linked votes

After all reviews, re-run `scan.sh`, then for each ticket with two or more active PRs:

- any non-Draft PR at −5 → every other non-Draft PR of the ticket at −5 (reply with the
  sibling link if the PR's own review was clean);
- no PR at −5 any more → restore each PR's own merited vote (from its latest review file), with a
  one-line marked reply.

Draft siblings get a comment only. Never touch merged PRs.

## 6. Report

One block per PR handled: reasons, verdict, vote (live or dry-run), thread id, review file. Then
the tickets whose linked votes changed. No Chat message from this skill — the reminder is a
separate job (`wfa-reminder`).
