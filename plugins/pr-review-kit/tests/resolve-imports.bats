#!/usr/bin/env bats
load helpers

@test "import-only conflict hunks are merged as a union" {
  f="$BATS_TEST_TMPDIR/A.java"
  printf 'package x;\n<<<<<<< ours\nimport a.B;\nimport a.C;\n=======\nimport a.C;\nimport a.D;\n>>>>>>> theirs\nclass A {}\n' > "$f"
  run python3 "$S/merge/resolve-imports.py" "$f"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^import' "$f")" -eq 3 ]
  ! grep -q '<<<<<<<' "$f"
}

@test "a logic conflict is left untouched" {
  f="$BATS_TEST_TMPDIR/B.java"
  printf '<<<<<<< ours\nint a = 1;\n=======\nint a = 2;\n>>>>>>> theirs\n' > "$f"
  cp "$f" "$f.orig"
  run python3 "$S/merge/resolve-imports.py" "$f"
  [ "$status" -eq 1 ]
  cmp "$f" "$f.orig"
}
