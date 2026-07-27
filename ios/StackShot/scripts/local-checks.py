#!/usr/bin/env python3
"""Pre-push checks that need no Swift toolchain.

This is NOT a substitute for SwiftLint or xcodebuild. It cannot type-check Swift,
so it cannot catch a compile error — the most common way a change breaks CI. What
it does catch is the subset of failures that are decidable by reading text, which
in practice is most of what has actually turned CI red on this project without
being a genuine logic mistake:

  * the SwiftLint rules whose severity is *error*, since only errors fail the job
  * two project-specific invariants whose violations were real, diagnosed bugs

Run it before pushing when CI budget is scarce:

    python3 ios/StackShot/scripts/local-checks.py

Exit status is 1 if anything would fail CI, 0 otherwise. Advisory findings are
printed but do not affect the exit status.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SWIFT_FILES = sorted(ROOT.glob("Sources/**/*.swift")) + sorted(ROOT.glob("Tests/**/*.swift"))

# From .swiftlint.yml plus SwiftLint's defaults. Only these fail the job; the
# warning thresholds (line_length 140, file_length 600) are deliberately noisy
# and are reported separately as advisory.
LINE_LENGTH_ERROR = 220
FILE_LENGTH_ERROR = 1000
LARGE_TUPLE_ERROR = 4          # warning at 3, error at 4

failures = []
advisories = []


def fail(path, line, rule, message):
    failures.append(f"{path.relative_to(ROOT)}:{line}: {rule}: {message}")


def advise(path, line, rule, message):
    advisories.append(f"{path.relative_to(ROOT)}:{line}: {rule}: {message}")


def strip_comment(line):
    """Good enough to keep `//`-commented examples from tripping the greps.

    Deliberately naive: it does not understand strings containing `//`. A false
    negative here costs a CI round; a false positive costs trust in the script,
    which is worse, so this errs toward staying quiet.
    """
    return line.split("//", 1)[0]


def tuple_arity(text, start):
    """Element count of the parenthesised group at `start`, or None if unbalanced.

    Counts commas at depth 1 only, so nested generics and function types inside
    the tuple don't inflate the count.
    """
    depth = 0
    commas = 0
    for i in range(start, len(text)):
        c = text[i]
        if c in "([<":
            depth += 1
        elif c in ")]>":
            depth -= 1
            if depth == 0:
                return commas + 1
        elif c == "," and depth == 1:
            commas += 1
    return None


def check_file(path):
    raw = path.read_text(encoding="utf-8")
    lines = raw.split("\n")
    # A file ending in a newline splits to a trailing empty element, which would
    # report one line more than SwiftLint does. Being off by one against the tool
    # you are predicting makes every number here suspect.
    if lines and lines[-1] == "":
        lines.pop()

    # file_length counts lines; SwiftLint ignores neither comments nor blanks for
    # the error threshold, so this matches its arithmetic.
    if len(lines) > FILE_LENGTH_ERROR:
        fail(path, len(lines), "file_length",
             f"{len(lines)} lines exceeds the error threshold of {FILE_LENGTH_ERROR}")
    elif len(lines) > 600:
        advise(path, len(lines), "file_length", f"{len(lines)} lines (warning at 600)")

    for n, line in enumerate(lines, 1):
        code = strip_comment(line)

        if len(line) > LINE_LENGTH_ERROR:
            fail(path, n, "line_length",
                 f"{len(line)} characters exceeds the error threshold of {LINE_LENGTH_ERROR}")
        elif len(line) > 140:
            advise(path, n, "line_length", f"{len(line)} characters (warning at 140)")

        # force_cast / force_try are error-severity by default in SwiftLint.
        if re.search(r"\bas!\s", code):
            fail(path, n, "force_cast", "`as!` is error-severity; use `as?` and handle nil")
        if re.search(r"\btry!\s", code):
            fail(path, n, "force_try", "`try!` is error-severity; use `try` or `try?`")

        # large_tuple, in the two places a tuple type is spelled: a return type and
        # a type annotation. This is what turned CI red after a four-collaborator
        # test fixture was written as a tuple.
        for match in re.finditer(r"->\s*\(", code):
            arity = tuple_arity(code, match.end() - 1)
            if arity and arity >= LARGE_TUPLE_ERROR:
                fail(path, n, "large_tuple",
                     f"return tuple has {arity} members; error at {LARGE_TUPLE_ERROR}. "
                     "Use a named struct.")

    check_project_invariants(path, lines)


def check_project_invariants(path, lines):
    """Two rules SwiftLint cannot express, both of which encode a real bug.

    Neither is a lint nicety: the first guards a process-killing ObjC exception,
    the second a fix that took a CPU-profile to notice.
    """
    text = "\n".join(strip_comment(line) for line in lines)

    # An AVCaptureDevice configuration write without a held lock raises an
    # uncatchable NSInvalidArgumentException — the process dies. Every
    # lockForConfiguration must have an unlock, and the codebase pairs them with
    # `defer`. Unequal counts in a file means at least one path can escape.
    locks = len(re.findall(r"\blockForConfiguration\(\)", text))
    unlocks = len(re.findall(r"\bunlockForConfiguration\(\)", text))
    if locks != unlocks:
        fail(path, 1, "lock-balance",
             f"{locks} lockForConfiguration vs {unlocks} unlockForConfiguration — "
             "an unbalanced pair raises an uncatchable ObjC exception")

    # `Task.sleep` throws immediately on a cancelled task. Swallowing that with
    # `try?` inside a polling loop turns the loop into a busy-spin that runs to its
    # deadline burning a core. SettleWait is where that decision is made
    # deliberately and reported to the caller; anywhere else in Sources it is the
    # bug again.
    #
    # Tests are exempt: their settle helpers poll with exactly this spelling, on
    # tasks nobody cancels, and flagging them every run would teach you to skim
    # past the section that is supposed to matter.
    if path.name != "SettleWait.swift" and "Sources" in path.parts:
        for n, line in enumerate(lines, 1):
            if re.search(r"try\?\s*await\s+Task\.sleep", strip_comment(line)):
                advise(path, n, "sleep-cancellation",
                       "`try? await Task.sleep` discards cancellation. In a polling "
                       "loop this busy-spins; prefer SettleWait or handle the throw.")


def main():
    if not SWIFT_FILES:
        print("no Swift files found — is the path right?", file=sys.stderr)
        return 2

    for path in SWIFT_FILES:
        check_file(path)

    if advisories:
        print(f"advisory ({len(advisories)}) — these do not fail CI:")
        for item in advisories:
            print(f"  {item}")
        print()

    if failures:
        print(f"WOULD FAIL CI ({len(failures)}):")
        for item in failures:
            print(f"  {item}")
        print()
        print("Note: this script cannot type-check Swift. A clean run means no *known* "
              "text-level failure, not that the code compiles.")
        return 1

    print(f"{len(SWIFT_FILES)} Swift files checked, nothing that would fail CI.")
    print("This does NOT mean it compiles — only a Mac can tell you that.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
