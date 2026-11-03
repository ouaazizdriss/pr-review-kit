# Review checklist (policy v1.0.0)

The working method behind `core-rules.md`. Read it before every review. Every item comes from a
real false positive or a real missed defect; the lesson is stated, the anecdote is not.

## 1. Before reading the code

- **Read the whole discussion first** — every non-system thread: author replies to the review
  thread, other reviewers, questions addressed to the reviewer. A thread marked "fixed" proves
  nothing: check the code, and reopen the thread (`post.sh reopen`) when nothing was fixed.
- **Establish what changed since the last review** by the source tip, not by iteration dates.
  Azure DevOps creates a new iteration when the *target* branch moves; the tip is unchanged.
  A new push ⇔ the date the current tip was first seen is after the last review.
- **The PR description can change without a commit.** For a point about the description, re-read
  it live just before posting.
- **Retargeted PR**: when the target branch changed, compare the changed-file counts of the
  iterations. A jump from a handful of files to hundreds means the branch was cut from a newer
  release: 🔴 « do not merge », ask for a branch cut from the target.

## 2. Correctness

- Null handling and unboxing; `Optional.orElseThrow` on rows that may not exist; front-end
  `.map`/`.filter`/spread on `undefined`; storing an updater function into React state.
- Query semantics: deterministic `ORDER BY`, `NULLS FIRST/LAST`, non-unique results, pagination,
  wildcards silently dropped (contains → equality), sorting on analysed text fields, native
  results mapped to the wrong Java type.
- **Run unusual queries.** An operator applied to a parameter instead of an entity path (e.g.
  `:param IS EMPTY`) can make the repository bean fail at startup — the whole service, not one
  endpoint. A service test that mocks the repository never covers the query.
- **Fail closed**: the default or unmatched branch of a security, routing or SSO decision denies.
- Transaction boundaries: `noRollbackFor` only covers the annotated method; trace every proxied
  call in between and resolve its real transactional attribute (class-level annotations count).
- **A guard that tests a recently added column** passes for every older row where the column is
  NULL. Guard on the starting state instead.
- **Annotation hijack**: when fields are inserted right below an annotation (`@Value`,
  `@Autowired`, `@Column`), check the annotation still sits on its original field.
- Mutable objects hoisted out of a conversion loop silently lose cardinality.
- Round trips: a "symmetric" mapping fix must be checked both ways.

## 3. Before claiming something is missing or dead

- **Grep the property string, not class names**, at the base and at the source; count readers on
  both sides ("there were 3, the PR removes 2" — a partial kill switch is worse than none).
- **Follow to a real caller.** A reader inside a private method with no caller is dead code; a
  rule that is written but never called protects nothing.
- **A declared bean is not the injected bean.** Find the bean actually injected at the call site;
  inspect an annotation's own meta-annotations before concluding it is decorative.
- Check upstream filters (view `WHERE` clauses, callers, guards) and existing test classes before
  raising « case not handled » or « missing test ».
- A copy of the same file in a repository the ticket does not touch is out of scope (➖).

## 4. Security grid (OWASP Top 10, targeted per diff)

| Change type | Look for |
|---|---|
| New or changed endpoint, query, filter | **A01** access control: tenant / owner scoping, Insecure Direct Object Reference, fail-closed default · **A03** injection: native queries, unvalidated input, XSS in templates and front rendering |
| Access-control fix | Does it bite **in the ticket's own scenario**? Compare the owner argument with what other callers pass; walk each validator branch for the ticket's context; look for fail-open formats; a test that mocks the validator with `any()` proves nothing |
| Service-to-service guard | Open the calling repository: does it really send a token? An unauthenticated call that is swallowed in a `catch` is green in tests and silent in production |
| Front-end control (disabled field, hidden button, client validation) | The back end must enforce it too |
| Auth, session, identity provider | **A07** |
| Configuration, Helm, pipelines | **A05** dev URLs or credentials in production config, debug levels · **A02** committed secrets, data in clear. Never print a secret: compare by key name and SHA-256 |
| Dependencies | **A06** suspicious pins or downgrades — check the real version lineage across services before calling it a regression |
| Logging | **A09** personal data, bodies, tokens in logs; ticket keys inside emitted log messages (comments and Javadoc are fine) |
| Outbound HTTP with a user-influenced URL | **A10** SSRF |
| Migration recreating a view (`DROP` + `CREATE`) | ownership, grants, `security_barrier` / `security_invoker` are lost → privilege escalation |

Do **not** raise "HTTP header injection" on an embedded Tomcat service: it neutralises CR/LF in
header values. The real defect in a hand-built `Content-Disposition` is the missing RFC 5987
`filename*` encoding (🟡).

## 5. Tools (run them, then verify every finding against the diff)

| Script | When | Reading the result |
|---|---|---|
| `scan-pr.sh <repo> <id>` | back-end repositories, non-Draft | Semgrep on changed files; Trivy only when dependencies/IaC changed, CVEs diffed against the base. Candidates only: keep a finding only if it is real **and introduced by this PR**; drop false positives silently |
| `check-test-compile.sh <repo> <id>` | Maven back-end repositories | `pr-broken` → 🟠 « Tests do not compile » with the errors · `already-broken` → ➖ note · `env-unverifiable` / `pr-broken-unconfirmed` → brief note, not blocking · `ok` / `not-maven` → nothing · `build-files-changed` → not built: read the listed build files by hand (new or changed plugins, extensions, repositories, annotation processors) and say so in one line |
| `check-merge.sh <repo> <id>` | every non-Draft PR | target `conflicts` → 🟠 « Merge conflict » (list files, ask for a rebase) · textual conflict with a sibling → 🟡 « Conflict with sibling PR #X » + merge order (➖ if the sibling is Draft or the other rebase resolves it) · semantic risk (clean trial merge, shared files) → read both diffs for duplicated symbols, imposed order, shared invariant: 🟠 if confirmed, **nothing** otherwise |
| `jira-issue.sh <KEY>` | every PR with a key | ticket line (advisory): 404 → 🟠 « ticket not found » · done/resolved while the PR is open → 🟠 · type or scope mismatch → 🟡 |

A failing script is noted briefly and the review continues with the manual grid.

After a sibling PR merges, re-check the remaining one against the **new** target tip: two clean
merges can still lose a check. `mergeStatus` is computed against the old base.

## 6. Tests

- For each assertion ask: **would it pass before the fix?** If yes, it guards nothing.
- Never conclude "tests green" from the touched class alone: compare the counts of tests,
  failures and errors at the base and at the source — that clears a PR as often as it blames one.
- A new `final` dependency + `@InjectMocks` without the matching `@Mock` = a silent NPE at run time.
- A suite already red hides new failures: compare counters, not colours.

## 7. Multi-branch and multi-PR work

- Same-title PRs on one repository are usually branch variants (develop vs release lines).
  Compare the **source content** of the files (and their checksums), not the diffs: the variant
  ahead also carries the removal of code already merged. Findings must match across variants.
- A PR targeting only a release branch: check the default branch still has the defect and look
  for the twin PR. A missing twin is a ➖ process note, never 🟠/−5 on its own.
- Stacked PRs: attribute each finding to the PR that **introduces** the line.

## 8. Before posting

- Re-read the source tip and PR status (`post.sh --expect-tip <sha>` enforces it). If the tip
  moved, re-check at least the 🔴/🟠 points.
- If a posted point turns out to be stale, post an explicit correction in the same thread: name
  the analysed commit and the fixing commit, withdraw the point.
- Never write "no push since X" without re-reading the iterations.
