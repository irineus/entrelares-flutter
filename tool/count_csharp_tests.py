#!/usr/bin/env python3
"""Counts xUnit test CASES in `db-gate/`, the way `dotnet test` does.

T-56's port to Dart is verified by ONE number: `C# tests + Dart tests` must stay
at 225 through every PR of the crossing. That only works if both sides are
counted the same way, and xUnit's own arithmetic is not obvious — a `[Theory]`
contributes one case per `[InlineData]`, not one per method, and a
`[MemberData]` contributes as many as its source yields.

So this script exists to make the C# half of that sum mechanical rather than
remembered. It is deliberately dumb: it reads the files, it never builds.

Usage:
    python3 tool/count_csharp_tests.py [--per-file]
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SUITE = ROOT / "db-gate" / "Entrelares.IntegrationTests"

FACT = re.compile(r"^\s*\[Fact[\](]")
THEORY = re.compile(r"^\s*\[Theory[\](]")
INLINE = re.compile(r"^\s*\[InlineData[\](]")
MEMBER = re.compile(r"^\s*\[MemberData[\](]")


def count(path: pathlib.Path) -> int:
    """Cases in one file: a Fact is 1, a Theory is its InlineData rows."""
    cases = 0
    pending_inline = 0
    saw_theory = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if FACT.match(line):
            cases += 1
            pending_inline, saw_theory = 0, False
        elif THEORY.match(line):
            saw_theory = True
        elif INLINE.match(line):
            pending_inline += 1
        elif MEMBER.match(line):
            print(
                f"{path.name}: [MemberData] found — this script cannot count it; "
                "count that theory by hand.",
                file=sys.stderr,
            )
        elif saw_theory and line.strip().startswith("public "):
            # The theory's own signature closes it: attribute block is over.
            cases += pending_inline
            pending_inline, saw_theory = 0, False
    return cases


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--per-file", action="store_true")
    args = parser.parse_args()

    if not SUITE.is_dir():
        # The last PR of the port deletes `db-gate/` — an absent suite is the
        # SUCCESS state, not an error.
        print("0  (db-gate/ is gone — the port is complete)")
        return 0

    total = 0
    for path in sorted(SUITE.glob("*Tests.cs")):
        n = count(path)
        total += n
        if args.per_file and n:
            print(f"{n:4d}  {path.name}")
    print(f"{total:4d}  TOTAL (C#)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
