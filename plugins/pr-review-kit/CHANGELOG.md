# Changelog

All notable changes to the kit. The version is the `version` field of
`.claude-plugin/plugin.json`: **installed copies update only when it changes.**

- **Patch** (x.y.**z**): script fixes, false positives removed — no vote changes.
- **Minor** (x.**y**.0): a new check or setting.
- **Major** (**x**.0.0): a change to a vote rule. Announced two weeks ahead; run it in dry-run first.

## 1.0.1 — 2026-11-03

- `wfa-reminder.sh`: card wording can be overridden with `WFA_TITLE`, `WFA_SUBTITLE` (`{n}` = PR count)
  and `WFA_NO_TICKET`; without them, the built-in English/French text follows `REVIEW_LANGUAGE`.
- Neutral placeholders in the usage examples of `check-pr-deployed.sh` and `list-prs-by-ticket.sh`.

## 1.0.0 — 2026-10-16

First packaged release, extracted from an existing team review workspace.

- Skills: `setup`, `doctor`, `review-pr`, `review-loop`, `wfa-reminder`, `merge-deploy`.
- Policy v1.0.0: core rules P1–P13 and hard rules, review checklist, migration-repository rules,
  merge and release rules, `strict` and `standard` profiles.
- `post.sh` is the single write path for comments and votes, with `POST_MODE`
  (`dry-run` default), marker, wording, tip, Draft, self-vote, −10 and required-reviewer guards,
  and a votes ledger (`state/votes.jsonl`).
- Candidate detection: new, push (by first-push date of the tip and by the ledger), Draft →
  Active, human reply, owner decision, merge conflict, team-assigned, vote reset, no ticket.
- Every team value moved to the workspace `config.env`; the reviewer id is resolved at runtime.
- Test suite (bats) with a fake `curl`: no network needed.
