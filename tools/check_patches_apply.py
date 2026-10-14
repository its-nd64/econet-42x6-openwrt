#!/usr/bin/env python3
"""Apply openwrt/patches/*.patch to the pinned upstream tree, offline from CI.

`scripts/apply-overlay.sh` applies this series with `git apply` to a tree cloned
at OPENWRT_COMMIT.  Everything that series touches lives in openwrt/openwrt, which
is public, so the whole thing can be verified without that tree: fetch the files
at the pin into a scratch repository, then apply the series exactly as the build
script does, in order, and stop at the first patch git refuses.

Why this exists: `tools/check_patches.py` verifies that each patch is
well-formed -- hunk counts match, headers present -- and a series can be perfectly
well-formed and still not apply, because a patch written in a tree that had already
drifted does not necessarily apply to a clean one.  That is not theoretical: CI
failed on patch 0006 after twenty seconds of looking at a tree it had just cloned,
having passed every local check, and the fix was to regenerate the patch against
the pin.

The kernel patches under openwrt/overlay are not covered: they are applied inside
the kernel build against kernel sources, which this cannot reproduce.

Usage:  tools/check_patches_apply.py [--root DIR] [--keep]
        --root DIR   tree to read openwrt/patches and scripts/pin.env from
        --keep       keep the scratch repository (to inspect what applied)

Exit status is 0 when the series applies, 1 when it does not, and 0 with a
"SKIPPED" line when the upstream files cannot be fetched -- a network problem is
not a patch problem, and failing lint for it would train people to ignore it.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

RAW = "https://raw.githubusercontent.com/openwrt/openwrt/%s/%s"
# pin.env is sourced by the shell scripts, so the value is quoted there; a hex
# commit hash is what this needs, with or without the quotes.
PIN_RE = re.compile(r'^\s*OPENWRT_COMMIT\s*=\s*"?(?P<commit>[0-9a-f]{7,40})"?',
                    re.M)


def read_pin(root):
    path = os.path.join(root, "scripts", "pin.env")
    with open(path, encoding="utf-8") as fh:
        match = PIN_RE.search(fh.read())
    if not match:
        raise SystemExit("!! no OPENWRT_COMMIT=<hex> in %s" % path)
    return match.group("commit")


def series(root):
    directory = os.path.join(root, "openwrt", "patches")
    names = sorted(n for n in os.listdir(directory) if n.endswith(".patch"))
    if not names:
        raise SystemExit("!! no patches in %s" % directory)
    return [os.path.join(directory, n) for n in names]


def touched(path):
    out = []
    for line in open(path, encoding="utf-8").read().splitlines():
        if line.startswith("+++ b/"):
            out.append(line[6:].strip())
    return out


def fetch(pin, path):
    """The upstream file, or None when the patch is expected to create it.

    Bytes, and normalised to LF: raw.githubusercontent serves LF, but this also
    runs on Windows, where a proxy or a tool in the middle can hand back CRLF, and
    a CRLF file silently stops matching every LF context in every patch.
    """
    try:
        with urllib.request.urlopen(RAW % (pin, path), timeout=30) as resp:
            data = resp.read()
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise
    return data.replace(b"\r\n", b"\n").decode("utf-8")


def git(work, *args):
    return subprocess.run(["git"] + list(args), cwd=work, capture_output=True,
                          text=True)


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--root", default=os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))))
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()

    root = os.path.abspath(args.root)
    pin = read_pin(root)
    patches = series(root)

    work = tempfile.mkdtemp(prefix="42x6-patches-")
    try:
        git(work, "init", "-q")
        git(work, "config", "user.email", "check@local")
        git(work, "config", "user.name", "check")
        # On Windows these two decide whether git rewrites every patched file to
        # CRLF, which makes the *next* patch in the series fail to match.
        git(work, "config", "core.autocrlf", "false")
        git(work, "config", "core.eol", "lf")

        wanted = []
        for patch in patches:
            for path in touched(patch):
                if path not in wanted:
                    wanted.append(path)

        missing = []
        try:
            for path in wanted:
                text = fetch(pin, path)
                dest = os.path.join(work, path)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                if text is None:
                    missing.append(path)
                    continue
                with open(dest, "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(text)
        except Exception as exc:                       # noqa: BLE001 - reported
            print("SKIPPED: cannot fetch the pinned upstream tree (%s: %s)"
                  % (type(exc).__name__, exc))
            print("         the patch series was NOT verified")
            return 0

        print("pinned revision %s, %d patch file(s), %d upstream file(s)%s"
              % (pin[:12], len(patches), len(wanted) - len(missing),
                 ", %d created by the patches" % len(missing) if missing else ""))

        git(work, "add", "-A")
        git(work, "commit", "-qm", "pin %s" % pin)

        for patch in patches:
            name = os.path.basename(patch)
            check = git(work, "apply", "--check", patch)
            if check.returncode != 0:
                print("!! %s does not apply to the pinned tree" % name)
                verbose = git(work, "apply", "--check", "-v", patch)
                for line in (verbose.stdout + verbose.stderr).splitlines():
                    print("   " + line)
                print("   Regenerate it against the pin: docs/building.md,")
                print("   'Bumping the pinned revision'.  A hunk whose context")
                print("   lines are present can still be refused -- 0006 was --")
                print("   because a patch written in a tree that had already")
                print("   drifted carries that tree's line numbers and block")
                print("   positions, not just its text.")
                return 1
            git(work, "apply", patch)
            print("   applies   %s" % name)

        print("the whole series applies to a clean tree at the pin")
        return 0
    finally:
        if args.keep:
            print("scratch repository kept at %s" % work)
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
