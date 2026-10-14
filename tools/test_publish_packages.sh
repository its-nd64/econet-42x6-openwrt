#!/usr/bin/env bash
#
# Self-test for scripts/publish-packages.sh.
#
# The publisher runs in CI, after a two-hour build, and its job is to write a
# directory that other people will point apk at.  A failure path that writes a
# half-filled release directory is worse than a hard failure, because the URL in
# it looks usable -- so the failure paths are tested here, together with the
# layout of the happy path.
#
# Everything happens in a temporary directory holding a fake build tree; no
# OpenWrt tree and no real package is involved.  Run from anywhere:
#
#     tools/test_publish_packages.sh
#
# Exit status is 0 when every case behaves as documented.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
PUBLISH="$REPO/scripts/publish-packages.sh"

PYTHON="${PYTHON:-python3}"
export PYTHON
export GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-realldz/econet-42x6-openwrt}"

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t 42x6test)
trap 'rm -rf "$WORK"' EXIT

TARGET_BIN="bin/targets/airoha/en7523"
CASES=0

fail() {
	echo
	echo "FAIL: $*" >&2
	echo "(the fake tree is gone; re-run with the line above in mind)" >&2
	exit 1
}

# expect_exit <status> <substring-in-output> <args...>
expect_exit() {
	want=$1
	needle=$2
	shift 2
	out=$("$PUBLISH" "$@" 2>&1)
	got=$?
	CASES=$((CASES + 1))
	if [ "$got" != "$want" ]; then
		echo "$out" >&2
		fail "expected exit $want, got $got: $*"
	fi
	if [ -n "$needle" ]; then
		case "$out" in
			*"$needle"*) ;;
			*) echo "$out" >&2; fail "output does not mention '$needle': $*" ;;
		esac
	fi
}

# --- a fake build tree ------------------------------------------------------
KERNEL="6.18.54-1-0123456789ab"

mk_tree() {
	root=$1
	mkdir -p "$root/$TARGET_BIN/kmods/$KERNEL"
	printf 'C: fake index\n' > "$root/$TARGET_BIN/kmods/$KERNEL/packages.adb"
	printf 'fake' > "$root/$TARGET_BIN/kmods/$KERNEL/kmod-mt7915e-6.18.54-r1.apk"
	printf 'fake' > "$root/$TARGET_BIN/kmods/$KERNEL/kmod-i2c-mt7621-6.18.54-r1.apk"
	# An image, so the metadata has something to hash.
	head -c 4096 /dev/zero > "$root/$TARGET_BIN/openwrt-airoha-en7523-econet_vgp-42x6v1-squashfs-sysupgrade.bin"
	# Two usable feeds and one that is only an empty directory.
	mkdir -p "$root/bin/packages/aarch64_cortex-a53/base" \
	         "$root/bin/packages/aarch64_cortex-a53/luci" \
	         "$root/bin/packages/aarch64_cortex-a53/empty"
	printf 'C: base\n' > "$root/bin/packages/aarch64_cortex-a53/base/packages.adb"
	printf 'fake' > "$root/bin/packages/aarch64_cortex-a53/base/apk-tools-3.0-r1.apk"
	printf 'C: luci\n' > "$root/bin/packages/aarch64_cortex-a53/luci/packages.adb"
	printf 'fake' > "$root/bin/packages/aarch64_cortex-a53/luci/luci-ssl-1-r1.apk"
}

echo "== wrong build trees must be refused, with a reason"
mkdir -p "$WORK/empty/$TARGET_BIN"
expect_exit 1 "no directory with a package index and kernel modules" \
	"$WORK/empty" --tag v0.1.0 --out "$WORK/out"

mkdir -p "$WORK/two/$TARGET_BIN/kmods/6.18.54-1-aaa" "$WORK/two/$TARGET_BIN/kmods/6.18.54-1-bbb"
: > "$WORK/two/$TARGET_BIN/kmods/6.18.54-1-aaa/packages.adb"
: > "$WORK/two/$TARGET_BIN/kmods/6.18.54-1-bbb/packages.adb"
expect_exit 1 "more than one kernel" "$WORK/two" --tag v0.1.0 --out "$WORK/out"

mkdir -p "$WORK/noindex/$TARGET_BIN/kmods/6.18.54-1-ccc"
: > "$WORK/noindex/$TARGET_BIN/kmods/6.18.54-1-ccc/kmod-x.apk"
expect_exit 1 "no directory with a package index and kernel modules" \
	"$WORK/noindex" --tag v0.1.0 --out "$WORK/out"

# A target packages directory that holds no kernel module is not the directory
# that makes a module installable, so it must not be published as if it were.
mkdir -p "$WORK/userspaceonly/$TARGET_BIN/packages"
printf 'C: core\n' > "$WORK/userspaceonly/$TARGET_BIN/packages/packages.adb"
printf 'fake' > "$WORK/userspaceonly/$TARGET_BIN/packages/base-files-1-r1.apk"
expect_exit 1 "no directory with a package index and kernel modules" \
	"$WORK/userspaceonly" --tag v0.1.0 --out "$WORK/out"

# Modules for two kernels in one directory: the invisible mistake, because
# whichever module is installed from the other kernel fails to load, and the
# repository itself looks fine.
mkdir -p "$WORK/mixedkernel/$TARGET_BIN/packages"
printf 'C: core\n' > "$WORK/mixedkernel/$TARGET_BIN/packages/packages.adb"
printf 'fake' > "$WORK/mixedkernel/$TARGET_BIN/packages/kmod-mt7915e-6.18.54-r1.apk"
printf 'fake' > "$WORK/mixedkernel/$TARGET_BIN/packages/kmod-old-6.12.0-r1.apk"
expect_exit 1 "for more than one kernel" "$WORK/mixedkernel" --tag v0.1.0 --out "$WORK/out"

mkdir -p "$WORK/nofeed/$TARGET_BIN/kmods/$KERNEL" "$WORK/nofeed/bin/packages/aarch64_cortex-a53/base"
printf 'C: x\n' > "$WORK/nofeed/$TARGET_BIN/kmods/$KERNEL/packages.adb"
printf 'fake' > "$WORK/nofeed/$TARGET_BIN/kmods/$KERNEL/kmod-x.apk"
expect_exit 1 "no feed under" "$WORK/nofeed" --tag v0.1.0 --out "$WORK/out" --with-feeds

# The refusal above happens after the kernel modules were found.  If the script
# copied them before checking the feeds, this directory would exist with a
# complete-looking UUID in it.
CASES=$((CASES + 1))
[ -e "$WORK/out/v0.1.0" ] && fail "a refused run left $WORK/out/v0.1.0 behind"

echo "== a good build tree produces a usable repository"
mk_tree "$WORK/good"
expect_exit 0 "" "$WORK/good" --tag v0.1.0 --out "$WORK/repo" --with-feeds
DEST="$WORK/repo/v0.1.0"

for want in \
	"$DEST/kmods/$KERNEL/packages.adb" \
	"$DEST/kmods/$KERNEL/kmod-mt7915e-6.18.54-r1.apk" \
	"$DEST/packages/aarch64_cortex-a53/base/packages.adb" \
	"$DEST/packages/aarch64_cortex-a53/luci/packages.adb" \
	"$DEST/metadata.json" \
	"$DEST/install.md" \
	"$WORK/repo/releases.json" \
	"$WORK/repo/index.html" \
	"$WORK/repo/.nojekyll"
do
	CASES=$((CASES + 1))
	[ -e "$want" ] || fail "expected $want to exist"
done

CASES=$((CASES + 1))
[ -e "$DEST/packages/aarch64_cortex-a53/empty" ] && fail "the empty feed was published anyway"

# The install note has to carry the exact directory, or somebody will guess it.
CASES=$((CASES + 1))
grep -q "kmods/$KERNEL" "$DEST/install.md" || fail "install.md does not name the kmod directory"
CASES=$((CASES + 1))
grep -q "allow-untrusted" "$DEST/install.md" || fail "install.md does not mention --allow-untrusted"

CASES=$((CASES + 1))
"$PYTHON" - "$DEST/metadata.json" "$KERNEL" <<'PY' || fail "metadata.json is not what it should be"
import json, sys

meta = json.load(open(sys.argv[1]))
assert meta["kernel"] == sys.argv[2], meta
assert meta["kmods"] == "kmods/%s/" % sys.argv[2], meta
assert meta["userspace_feeds"] == 2, meta
assert len(meta["images"]) == 1 and meta["images"][0]["size"] == 4096, meta
assert len(meta["images"][0]["sha256"]) == 64, meta
PY

echo "== the layout this board's own build produces: packages/, not kmods/"
# Measured on a real build of this board: 73 packages, among them
# kmod-xpon-6.18.54-r1.apk, all under bin/targets/airoha/en7523/packages/.  An
# earlier version of the publisher required kmods/<kernel>/ and would have failed
# the CI run at the last step, after the whole build.
mkdir -p "$WORK/mixed/$TARGET_BIN/packages"
printf 'C: core\n' > "$WORK/mixed/$TARGET_BIN/packages/packages.adb"
printf 'fake' > "$WORK/mixed/$TARGET_BIN/packages/kmod-mt7915e-6.18.54-r1.apk"
printf 'fake' > "$WORK/mixed/$TARGET_BIN/packages/kmod-i2c-mt7621-6.18.54-r1.apk"
# Not a module: it has to be published too, because the index next to it lists it.
printf 'fake' > "$WORK/mixed/$TARGET_BIN/packages/base-files-1-r1.apk"
head -c 4096 /dev/zero > "$WORK/mixed/$TARGET_BIN/openwrt-airoha-en7523-econet_vgp-42x6v1-squashfs-sysupgrade.bin"
expect_exit 0 "" "$WORK/mixed" --tag v0.2.0 --out "$WORK/mixedrepo"
MIXED="$WORK/mixedrepo/v0.2.0"

CASES=$((CASES + 1))
[ -e "$MIXED/kmods/6.18.54/packages.adb" ] \
	|| fail "the kernel version was not read out of the module file names"

for want in \
	"$MIXED/kmods/6.18.54/kmod-mt7915e-6.18.54-r1.apk" \
	"$MIXED/kmods/6.18.54/base-files-1-r1.apk"
do
	CASES=$((CASES + 1))
	[ -e "$want" ] || fail "expected $want to exist (the index lists it)"
done

CASES=$((CASES + 1))
"$PYTHON" - "$MIXED/metadata.json" <<'PY' || fail "metadata.json is wrong for the packages/ layout"
import json, sys

meta = json.load(open(sys.argv[1]))
assert meta["kernel"] == "6.18.54", meta
assert meta["kmods"] == "kmods/6.18.54/", meta
assert meta["source_dir"] == "bin/targets/airoha/en7523/packages", meta
assert meta["kernel_modules"] == 2, meta
assert meta["packages_published"] == 3, meta
PY

CASES=$((CASES + 1))
grep -q "kmods/6.18.54" "$MIXED/install.md" \
	|| fail "install.md does not name the published directory"

echo "== an opkg-era tree (Packages) is still accepted"
mkdir -p "$WORK/opkg/$TARGET_BIN/kmods/5.15.0"
: > "$WORK/opkg/$TARGET_BIN/kmods/5.15.0/Packages"
: > "$WORK/opkg/$TARGET_BIN/kmods/5.15.0/kmod-x_5.15.0-1_aarch64_cortex-a53.ipk"
expect_exit 0 "" "$WORK/opkg" --tag v0.1.0 --out "$WORK/repo"

echo "== publishing the same tag twice does not duplicate it"
expect_exit 0 "" "$WORK/good" --tag v0.1.0 --out "$WORK/repo" --with-feeds
CASES=$((CASES + 1))
"$PYTHON" - "$WORK/repo/releases.json" <<'PY' || fail "releases.json has a duplicate entry"
import json, sys

tags = [e["tag"] for e in json.load(open(sys.argv[1]))]
assert len(tags) == len(set(tags)), tags
PY

echo "== the landing page follows releases.json, not the tag of the last run"
expect_exit 0 "" "$WORK/good" --tag v0.9.9 --out "$WORK/repo"
expect_exit 0 "" "$WORK/good" --tag v0.1.0 --out "$WORK/repo" --with-feeds
CASES=$((CASES + 1))
newest=$("$PYTHON" - "$WORK/repo/releases.json" <<'PY'
import json, sys

print(json.load(open(sys.argv[1]))[0]["tag"])
PY
)
CASES=$((CASES + 1))
grep -q "href=\"$newest/install.md\"" "$WORK/repo/index.html" \
	|| fail "index.html does not point at '$newest', the first entry of releases.json"

echo
echo "ok: $CASES check(s) passed"
