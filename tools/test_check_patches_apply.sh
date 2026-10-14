#!/usr/bin/env bash
#
# Self-test for tools/check_patches_apply.py.
#
# A gate that only ever says "the whole series applies" is worse than none: it
# would have said that about the series that failed CI.  So this plants a patch
# that cannot apply and checks that the gate refuses it, by name.
#
# Needs the network (the gate fetches the pinned upstream files).  If that is
# unavailable the gate reports SKIPPED and this test says so instead of failing:
# a network problem is not a patch problem.
#
#     tools/test_check_patches_apply.sh

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
CHECK="$REPO/tools/check_patches_apply.py"
PYTHON="${PYTHON:-python3}"

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t 42x6pcheck)
trap 'rm -rf "$WORK"' EXIT

fails=0
checks=0

# A minimal tree for the gate to read: the real pin and the real patch series.
mkdir -p "$WORK/root/scripts" "$WORK/root/openwrt/patches"
cp "$REPO/scripts/pin.env" "$WORK/root/scripts/"
cp "$REPO"/openwrt/patches/*.patch "$WORK/root/openwrt/patches/"

echo "== the real series is accepted"
out=$("$PYTHON" "$CHECK" --root "$WORK/root" 2>&1)
status=$?
checks=$((checks + 1))
if printf '%s' "$out" | grep -q '^SKIPPED'; then
	echo "skip the pinned tree could not be fetched; the gate was not exercised"
	printf '%s\n' "$out" | head -2
	exit 0
fi
if [ "$status" -ne 0 ]; then
	echo "FAIL the real series was refused:" >&2
	printf '%s\n' "$out" >&2
	fails=$((fails + 1))
elif ! printf '%s' "$out" | grep -q 'the whole series applies'; then
	echo "FAIL the gate did not say the series applies:" >&2
	printf '%s\n' "$out" >&2
	fails=$((fails + 1))
else
	echo "ok   the real series applies to the pinned tree"
fi

echo "== a patch whose context does not exist is refused, by name"
cat > "$WORK/root/openwrt/patches/0008-deliberately-broken.patch" <<'EOF'
diff --git a/target/linux/airoha/modules.mk b/target/linux/airoha/modules.mk
--- a/target/linux/airoha/modules.mk
+++ b/target/linux/airoha/modules.mk
@@ -1,3 +1,4 @@
 # this context line does not exist anywhere in the file
 # and neither does this one
 # nor this one
+a line that will therefore never be added
EOF
out=$("$PYTHON" "$CHECK" --root "$WORK/root" 2>&1)
status=$?
checks=$((checks + 1))
if [ "$status" -eq 0 ]; then
	echo "FAIL a broken patch was accepted:" >&2
	printf '%s\n' "$out" >&2
	fails=$((fails + 1))
elif ! printf '%s' "$out" | grep -q '0008-deliberately-broken.patch does not apply'; then
	echo "FAIL refused, but without naming the patch:" >&2
	printf '%s\n' "$out" >&2
	fails=$((fails + 1))
else
	echo "ok   the broken patch is refused and named"
fi

echo "== a hunk that inserts at the end of its context is what broke 0006"
# The regression itself: same file, context lines that DO exist, insertion after
# the last context line and no context line after it.  Whatever git's reason, this
# shape must not be accepted silently -- if git refuses it, the gate has to say so.
rm -f "$WORK/root/openwrt/patches/0008-deliberately-broken.patch"
cat > "$WORK/root/openwrt/patches/0009-insert-at-end.patch" <<'EOF'
diff --git a/target/linux/airoha/modules.mk b/target/linux/airoha/modules.mk
--- a/target/linux/airoha/modules.mk
+++ b/target/linux/airoha/modules.mk
@@ -1,1 +1,2 @@
 # SPDX-License-Identifier: GPL-2.0-only
+EXTRA_CFLAGS += -DNOTHING
EOF
out=$("$PYTHON" "$CHECK" --root "$WORK/root" 2>&1)
status=$?
checks=$((checks + 1))
if [ "$status" -eq 0 ]; then
	echo "ok   git accepts this shape (the gate agreed it applies)"
elif printf '%s' "$out" | grep -q '0009-insert-at-end.patch'; then
	echo "ok   git refuses this shape and the gate says which patch"
else
	echo "FAIL refused without naming the patch:" >&2
	printf '%s\n' "$out" >&2
	fails=$((fails + 1))
fi

echo
if [ "$fails" -ne 0 ]; then
	echo "$fails of $checks check(s) FAILED" >&2
	exit 1
fi
echo "ok: $checks check(s) passed"
