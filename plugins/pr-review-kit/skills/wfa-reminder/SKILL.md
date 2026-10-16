---
name: wfa-reminder
description: Post the "waiting for the author" reminder to the team's Google Chat space — one card listing every active allow-listed PR where the reviewer's vote is −5, with links to the PR and ticket and the author's name. Sends nothing when the list is empty. Use when asked to send the reminder, or on a schedule.
argument-hint: "[--dry-run]"
---

# Waiting-for-author reminder

Run only the reminder — no review, no vote in this job:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/wfa-reminder.sh" $ARGUMENTS
```

**Workspace.** The configured workspace is `${user_config.workspace}`. If that is a real path
(not empty, not a literal placeholder), prefix every kit command with `PRR_WORKSPACE="<that path>"`.
Otherwise run the commands as written: the scripts use `$PRR_WORKSPACE` from the environment, or
the folder recorded by setup in `~/.config/pr-review-kit/workspace`.

With `--dry-run` the card JSON is printed instead of sent. The script is read-only against Azure
DevOps and writes only to the webhook in `GCHAT_WEBHOOK_URL`; without it the script is dormant and
says so. Report the script's one-line result. Never print the webhook URL.
