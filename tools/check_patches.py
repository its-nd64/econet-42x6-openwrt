#!/usr/bin/env python3
"""Check, and optionally repair, the hunk headers of unified diffs.

Why this exists
---------------
The overlay carries patches that were written by hand (`diff -ruN`, then edited).
Editing a hunk body without updating its `@@ -a,b +c,d @@` header leaves a patch
that `git apply` refuses:

    error: corrupt patch at openwrt/.../940-03-...patch:20

The line number it names is the *next* hunk header, not the hunk that is wrong --
so the message points at the wrong place.  `git apply --check` also stops at the
first bad file, so one broken patch hides the rest.  This tool walks every hunk,
counts its body, and names the hunk whose counts are wrong.

Usage
-----
    tools/check_patches.py <file-or-dir> [more...]
    tools/check_patches.py --fix <file-or-dir> [more...]

`--fix` rewrites only the broken headers, recomputing the counts from the body
(the same numbers `git apply --recount` would use).  It never touches a hunk
whose counts are already consistent, so a clean tree stays byte-identical.

Exit status is 0 when every hunk is consistent, 1 otherwise.
"""

import argparse
import os
import re
import sys

HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$")
PATCH_SUFFIXES = (".patch", ".diff")


def iter_patches(paths):
    """Yield every .patch/.diff file under the given paths, in a stable order."""
    for path in paths:
        if os.path.isdir(path):
            for root, dirs, files in os.walk(path):
                dirs.sort()
                for name in sorted(files):
                    if name.endswith(PATCH_SUFFIXES):
                        yield os.path.join(root, name)
        elif os.path.isfile(path):
            yield path
        else:
            raise SystemExit("!! no such file or directory: %s" % path)


def is_file_header(lines, i):
    """True when lines[i] is a `--- ` ... `+++ ` pair, i.e. a new file section.

    A removed line whose content starts with `-- ` renders as `--- ...`, so the
    prefix alone is ambiguous: require the `+++ ` partner to treat it as a
    header rather than as hunk body.
    """
    if not lines[i].startswith("--- ") or i + 1 >= len(lines):
        return False
    return lines[i + 1].startswith("+++ ")


def ends_hunk(lines, i):
    """True when lines[i] starts a new section rather than continuing a hunk."""
    line = lines[i]
    if line.startswith("@@ -"):
        return True
    if line.startswith("diff ") or line.startswith("index ") or line.startswith("Binary files "):
        return True
    if is_file_header(lines, i):
        return True
    return False


def count_body(lines, start):
    """Count (old, new, ambiguous) for the hunk body beginning at `start`.

    Returns three values: the counts treating a completely empty line as the end
    of the hunk, the counts treating it as an empty context line (which is what
    git apply does), and whether the two disagree.
    """
    old_a = new_a = 0
    old_b = new_b = 0
    i = start
    stopped = False
    while i < len(lines):
        line = lines[i]
        if line.startswith("\\"):  # "\ No newline at end of file"
            i += 1
            continue
        if line == "":
            if stopped:
                break
            stopped = True
            i += 1
            continue
        if stopped or ends_hunk(lines, i):
            break
        head = line[:1]
        if head == " ":
            old_a += 1
            new_a += 1
            old_b += 1
            new_b += 1
        elif head == "-":
            old_a += 1
            old_b += 1
        elif head == "+":
            new_a += 1
            new_b += 1
        else:
            break
        i += 1
    return old_a, new_a, old_b, new_b


def check_file(path, fix):
    """Return a list of problem strings for one patch file, repairing if asked."""
    with open(path, "r", encoding="utf-8", newline="") as fh:
        text = fh.read()

    # Patches must keep their exact bytes; a CRLF conversion silently breaks them.
    crlf = "\r\n" in text
    lines = text.split("\n")
    problems = []
    fixed = 0

    for i, line in enumerate(lines):
        m = HUNK_RE.match(line)
        if not m:
            continue
        want_old = int(m.group(2)) if m.group(2) is not None else 1
        want_new = int(m.group(4)) if m.group(4) is not None else 1
        tail = m.group(5)

        got_old_a, got_new_a, got_old_b, got_new_b = count_body(lines, i + 1)

        ok = (got_old_a == want_old and got_new_a == want_new) or (
            got_old_b == want_old and got_new_b == want_new
        )
        if ok:
            continue

        if got_old_b != got_old_a or got_new_b != got_new_a:
            problems.append(
                "%s:%d: hunk @@ -%d,%d +%d,%d @@ -> body counts are ambiguous "
                "(empty line inside the hunk: %d,%d or %d,%d) -- look at this one by hand"
                % (path, i + 1, int(m.group(1)), want_old, int(m.group(3)), want_new,
                   got_old_a, got_new_a, got_old_b, got_new_b)
            )
            continue

        problems.append(
            "%s:%d: hunk @@ -%d,%d +%d,%d @@ -> body has %d,%d"
            % (path, i + 1, int(m.group(1)), want_old, int(m.group(3)), want_new,
               got_old_b, got_new_b)
        )
        if fix:
            old_hdr = "@@ -%d,%d +%d,%d @@%s" % (int(m.group(1)), want_old, int(m.group(3)), want_new, tail)
            new_hdr = "@@ -%d,%d +%d,%d @@%s" % (int(m.group(1)), got_old_b, int(m.group(3)), got_new_b, tail)
            lines[i] = new_hdr
            fixed += 1

    if crlf:
        problems.append("%s: file has CRLF line endings -- git apply will reject it" % path)

    if fix and fixed:
        with open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write("\n".join(lines))
        problems = [p for p in problems if "->" not in p]
        if not problems:
            print("fix  %s: repaired %d hunk header(s)" % (path, fixed))

    return problems


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--fix", action="store_true",
                    help="rewrite broken hunk headers with recount-derived counts")
    ap.add_argument("paths", nargs="+", help="patch files or directories to scan")
    args = ap.parse_args()

    all_problems = []
    scanned = 0
    for path in iter_patches(args.paths):
        scanned += 1
        all_problems.extend(check_file(path, args.fix))

    if all_problems:
        for problem in all_problems:
            print("BAD  " + problem)
        print("\n%d problem(s) in %d patch file(s)" % (len(all_problems), scanned))
        return 1

    print("ok   %d patch file(s), every hunk header matches its body" % scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main())
