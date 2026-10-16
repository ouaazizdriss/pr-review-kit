# Team notes

Team-specific knowledge the review skills read before every review, on top of the shipped
policy. Keep it factual: what is true about **your** repositories that a reviewer from
another team would get wrong. Each note: the rule, why, and how to check it.

## Architecture and contracts

- Example: shared DTOs and enums live in `my-shared-lib`; every consumer PR must match them.
  Merge order: library before its consumers.

## Known false positives

- Example: framework X already neutralises Y — do not raise it as 🟠.

## Release model

- Example: sprint N ships from `release/N.0.0`; a fix merged on a release is carried over to
  every later release, then `develop`.

## Migration repository

- Example: the release folder, not the git branch, is the delivery line; all migration PRs
  merge on `develop`.
