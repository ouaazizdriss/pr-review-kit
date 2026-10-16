#!/usr/bin/env python3
"""Resolve merge-conflict hunks that contain only import lines, by keeping the union of
both sides (first occurrence order). Any hunk with a non-import line leaves the file
untouched and exits 1, so a human resolves logic conflicts.

Usage: resolve-imports.py <file>...
"""
import re
import sys

HUNK = re.compile(
    r"<<<<<<< [^\n]*\n(.*?)(?:\|\|\|\|\|\|\| [^\n]*\n.*?)?=======\n(.*?)>>>>>>> [^\n]*\n",
    re.S,
)
IMPORT = re.compile(r"\s*import\s")


def resolve(text):
    ok = True

    def repl(match):
        nonlocal ok
        lines = [l for l in (match.group(1) + match.group(2)).split("\n") if l.strip()]
        if not all(IMPORT.match(l) for l in lines):
            ok = False
            return match.group(0)
        seen = []
        for line in lines:
            if line not in seen:
                seen.append(line)
        return "\n".join(seen) + "\n"

    return HUNK.sub(repl, text), ok


def main(paths):
    all_ok = True
    for path in paths:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        new, ok = resolve(text)
        if ok:
            with open(path, "w", encoding="utf-8") as f:
                f.write(new)
        all_ok = all_ok and ok
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
