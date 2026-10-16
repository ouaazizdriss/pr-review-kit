# Core review rules (policy v1.0.0)

These rules apply to every team. A team tunes the **settings** named under a rule in its
`config.env`; it never edits the rule. A change to a rule is a new policy version (see
`CHANGELOG.md`). Severity tags used everywhere: 🔴 blocking · 🟠 major · 🟡 minor · ✅ ok ·
➖ advisory (requires no change to this PR's code).

---

### P1 — Evidence over opinion
- **Statement:** every point cites the live code (`path:line`) at the reviewed source commit, and
  is judged on the real contribution of the PR: merge base (`commonRefCommit`) → source tip.
- **Rationale:** an iteration-to-iteration diff includes target-branch commits the author merged
  in; a diff read without its callers hides null-safety, query and cross-repo errors.
- **Implications:** fetch files at the base and source commits and diff them; read callers,
  entities and shared DTOs. Before calling a finding "introduced", check it is absent from the
  merge base and from the target tip. A point without evidence is dropped. A pre-existing defect
  is at most a ➖ out-of-scope note.

### P2 — One confirmed point blocks the merge
- **Statement:** with `POLICY_PROFILE=strict`, any confirmed point on the code — 🔴, 🟠 or 🟡 —
  sets the vote to **−5** (waiting for the author); **+10** only with zero code points. **−10 is
  never used.** With `standard`, 🔴/🟠 → −5, 🟡 only → +5, none → +10.
- **Rationale:** "approved with suggestions" PRs were merged with the suggestions still open.
- **Implications:** a point is lifted only by a fix, or by a pushback **verified against the
  code**. Notes that require no change to this PR's code do not block: Jira advisories, "port to
  the other branch = a separate PR", process suggestions, provably unreachable observations.
- **Setting:** `POLICY_PROFILE`.

### P3 — Back-end logic ships with unit tests
- **Statement:** new or changed back-end logic not covered by unit tests (in the PR, or
  demonstrably by existing tests) is a 🟠 « Missing tests » point (`path:line` of the logic).
- **Rationale:** regressions found in QA cost more than a test written with the change.
- **Implications:** cite covering tests as `TestClass#method` when they exist — check the
  existing test classes at the reviewed tip before raising the point. **Exempt:** front-end
  portals (`FRONT_REPOS`), shared libraries and starters (`LIBRARY_REPOS`: no coverage rule),
  migrations, i18n strings, pure configuration, one-line constants, version bumps, binary
  assets. Tests that **no longer compile** because of the PR are always 🟠, libraries included.
- **Settings:** `UNIT_TESTS_BLOCKING`, `FRONT_REPOS`, `LIBRARY_REPOS`.

### P4 — Security by a targeted grid
- **Statement:** each diff is screened against the OWASP Top 10 categories matching its change
  type (grid in `review-checklist.md`). Scanner output is a candidate, confirmed by hand.
- **Rationale:** a full checklist on every PR is noise, and noise is ignored.
- **Implications:** a confirmed finding is a « Security (OWASP Ax) » point with its normal
  severity. No finding → **no security section at all**. Write vulnerability classes out in full
  — « Insecure Direct Object Reference », not the acronym.

### P5 — A feature is approved as a whole
- **Statement:** the active PRs sharing a ticket key are voted together: while one non-Draft PR of
  the ticket is at −5, every other non-Draft PR of the ticket is at −5 too, even with zero points
  of its own, and its review links the blocking PR by its real URL.
- **Rationale:** half-approved multi-repository features were merged and broke the contract
  between services.
- **Implications:** wording: « Technically OK, held at −5 for ticket consistency: sibling PR #X
  is waiting for its author ». Restore each PR's own merited vote only when **no** sibling is at
  −5, whatever the sibling's reason. State the merge order (migrations → libraries → back-end →
  front-end; callee before caller). A PR stacked on another branch carries that branch's changes:
  it cannot be +10 while the PR it embeds has an open point.

### P6 — Traceability to a ticket
- **Statement:** every active non-Draft PR carries a key matching `TICKET_KEY_REGEX` in its title
  or source branch.
- **Rationale:** release reports, deployment checks and ticket moves depend on that key.
- **Implications:** no key → −5 and one reminder comment asking to link the ticket (once per PR,
  not every pass); restore the merited vote when the key appears. The ticket line of a review
  (existence, type, status) is **advisory** and never changes the vote.
- **Setting:** `TICKET_KEY_REGEX`, `JIRA_BASE`.

### P7 — Respect the author's workspace and the owner's decisions
- **Statement:** Draft PRs get comments only (the identity may be added as required reviewer with
  vote 0). All human comments are read before any re-review. A short unmarked comment posted under
  the reviewer identity is the **owner's manual decision** and is applied, never overwritten.
- **Rationale:** Draft is the author's signal that the work is not ready for judgement; a manual
  decision is an arbitration the automation must not undo.
- **Implications:** a Draft published without a new commit gets the vote its Draft review merits.
  Verify an author's "fixed" against the code; answer questions addressed to the reviewer;
  acknowledge a valid pushback and lift the point. A peer's independent review is input, not a
  re-review trigger. A PR whose owner removed the reviewer by hand goes in `EXCLUDED_PRS`.

### P8 — Configuration, not code
- **Statement:** org, project, repositories, team group, ticket pattern, language, profile and
  marker live in the workspace `config.env`; the kit contains none of them.
- **Implications:** the reviewer id is read at runtime from Azure DevOps (`connectionData`).

### P9 — A bot identity, not a person
- **Statement:** scheduled reviews and votes are cast by a dedicated service account per team.
- **Implications:** the identity cannot vote on PRs it authored — those are reviewed and commented
  only. Its token lives in a vault or pipeline variable group, never in files.

### P10 — Safe by default
- **Statement:** a new installation runs with `POST_MODE=dry-run`; posting is switched on by the
  team owner after a trial period.

### P11 — Idempotent and attributable
- **Statement:** every posted comment — replies and short notes included — starts with the team's
  unique `PR_MARKER`; the reviewer's comments are recognised by **author id and marker**.
- **Rationale:** loops sharing one marker read each other's reviews as their own; an unmarked
  comment under the reviewer identity reads as an owner decision (P7).

### P12 — Least privilege
- **Statement:** the review token reads code and PRs, comments and votes. Merging, pushing and
  deploying use a separate token (`AZURE_DEVOPS_MERGE_PAT`) and run only when a person asks.
  Reviews read Jira and never write to it.

### P13 — Auditable decisions
- **Statement:** each review is kept as a local file and as a PR thread; each vote cast is logged
  in `state/votes.jsonl` with the commit it judged; the history file gets one line per review.
- **Implications:** logs and review files never contain tokens or personal data.

---

## Hard rules (mechanically enforced by `scripts/post.sh`)

| Rule | Behaviour |
|---|---|
| Never −10 | refused; use −5 |
| Draft PRs | only vote 0 (required reviewer); comments allowed |
| Own PRs | no vote (Azure DevOps refuses the author's vote): comment only |
| Merged PR | comment allowed as post-merge feedback; vote refused |
| Required reviewer | every vote is `{"vote": n, "isRequired": true}` — a bare vote demotes the reviewer to optional |
| Tip moved | with `--expect-tip`, nothing is posted if the source tip changed since the analysis |
| Marker | prefixed when missing |
| Wording | a posted review never says it is generated or automated, and never names an AI vendor or model; it reads as an ordinary review |
| Posting mode | `POST_MODE` gates every write |

## Writing the comment

- Language: `REVIEW_LANGUAGE`. Tone: factual and courteous.
- Structure: verdict line, short summary of the change, the points (severity, `path:line`,
  what and why, a concrete fix), ticket line, merge order when relevant.
- Link PRs with their real URL `https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/<id>`,
  never a work-item URL. Link tickets as `[KEY](<JIRA_BASE>/browse/KEY)`.
- First review of a PR → a new thread. Re-review → a reply in the existing marked thread.
