# Migration repositories (policy v1.0.0)

Applies to the repositories listed in `SQL_REPOS`. Migrations are exempt from the unit-test rule
(P3) and from the scanners, but **not** from their own procedure.

## Rule: the repository's procedure is the standard

Fetch the procedure documents (`SQL_PROCEDURE_DOCS`, e.g. `/README.md` and `/MIGRATIONS.md`)
**at the PR source commit** and review the PR against them, citing their sections (§). Any
departure from the documented procedure is a 🟠 « Procedure (§X) » point at least → −5. What the
procedure itself tolerates is not a violation. A green lint is **not** proof of compliance: read
what the lint script actually checks before relying on it.

## Checklist (adapt the section numbers to your procedure)

- **Placement**: the file is in a valid release folder for the change. Several releases can be
  open at once; a migration in an older release that is still maintained is allowed. Flag only a
  folder that is genuinely closed for good, or a header / folder / manifest mismatch. When the
  team ties releases to sprints, a ticket's migrations go in its sprint's release folder (🟡 when
  one ticket's migrations are split across two releases).
- **Manifest**: listed exactly once, in the right manifest; the manifest is the order authority,
  not the numeric prefix. Prefix collisions between parallel PRs are tolerated and reconciled by
  the release owner — **never ask an author to renumber**. A manifest line pointing to a missing or
  renamed file is a real break.
- **Naming**: the documented pattern (e.g. `NNN_TICKET_description[.notx].sql`).
- **Idempotency**: `IF NOT EXISTS`, `ON CONFLICT` / `WHERE NOT EXISTS`, `CREATE OR REPLACE`,
  guarded constraints.
- **Transactions**: no `BEGIN/COMMIT` in a file the runner wraps, unless the procedure's
  no-transaction convention is followed and justified.
- **Rollback**: paired, symmetric and non-destructive, or a documented irreversibility waiver. A
  rollback `DELETE` can wipe a row the forward migration only relabelled.
- **Header**: metadata matches the real file name, folder and manifest (copied headers drift).
- **Business keys, not surrogate ids**. Check that the literal keys used in `WHERE` clauses exist
  in the current seed: an `UPDATE`/`DELETE` that matches nothing passes every linter.
- **Destructive operations** (`DROP`, `TRUNCATE`, `DELETE` of data): the author must flag them in
  the PR description; the release owner's sign-off is a branch-policy step, not a string the
  author writes in the header.
- **Feature PRs do not open or close releases** unless the procedure says so.

## Cross-migration effects

- Several migrations of one release redefining the same view: the **last** in manifest order wins
  and can silently revert an earlier fix. List every migration of the release touching the object.
- Recreating a view with `DROP` + `CREATE` loses owner, grants, column grants, comments and
  `security_barrier` / `security_invoker` → privilege escalation (see the security grid).
- Sequences behind `MAX(id)` after seeded inserts cause primary-key collisions.
- Reference tables need a unique constraint on their business key for idempotent upserts; review
  the table and its consumer service together.
- Identity-provider databases may use `varchar` ids: cast generated UUIDs.

## Delivery line

In some teams the **release folder** on the default branch is the delivery line, not a release
branch. Check the repository before asking for a twin PR on a release branch: if no release
branch contains its own release folder, the twin request has no object. State the team's model in
`team-notes.md`.
