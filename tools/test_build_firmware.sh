#!/usr/bin/env bash
# Exercise set_cfg() / set_cfg_off() from build-firmware.sh against a fake .config.
#
# Why this is worth a test: these two helpers decide what lands in .config before
# `make defconfig`, and the SEEDED file they write is what the post-defconfig gate
# greps for.  The two halves have to agree on spelling, and kconfig rewrites
# `CONFIG_FOO=n` as `# CONFIG_FOO is not set` -- so seeding an off symbol as `=n`
# would make the gate report a symbol it had just written itself, and the build
# would abort with a message that makes no sense.
#
# The specific hole this covers is the one in docs/sysupgrade.md: --no-initramfs
# used to leave a stale `=y` behind, and the sysupgrade image built that way was
# 12,058,913 B with the squashfs at 0x760000 instead of 9,437,473 B at 0x3A0000.
#
# Usage: tools/test_build_firmware.sh      (no dependencies beyond bash/sed/grep)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The helpers are pulled out of the script rather than copied, so this cannot
# drift into testing a stale duplicate of them.
sed -n '/^set_cfg() {/,/^}/p;/^set_cfg_off() {/,/^}/p' scripts/build-firmware.sh > "$WORK/helpers.sh"
if [ ! -s "$WORK/helpers.sh" ]; then
	echo "!! could not extract set_cfg/set_cfg_off from scripts/build-firmware.sh"
	exit 1
fi
# shellcheck disable=SC1090,SC1091
. "$WORK/helpers.sh"

fails=0
check() { # check <label> <exact-line> <file>
	if grep -qx "$2" "$3"; then
		echo "  ok   $1"
	else
		echo "  FAIL $1: expected the line '$2'"
		sed 's/^/       /' "$3"
		fails=$((fails + 1))
	fi
}
check_absent() { # check_absent <label> <exact-line> <file>
	if grep -qx "$2" "$3"; then
		echo "  FAIL $1: '$2' is still present"
		fails=$((fails + 1))
	else
		echo "  ok   $1"
	fi
}

echo "== a symbol that is currently =y, turned off (the stale-=y case)"
CFG=$(mktemp); SEEDED=$(mktemp)
printf 'CONFIG_TARGET_ROOTFS_INITRAMFS=y\nCONFIG_KERNEL_DEVTMPFS=y\n' > "$CFG"
set_cfg_off "CONFIG_TARGET_ROOTFS_INITRAMFS" >/dev/null
check_absent "the =y line is gone" "CONFIG_TARGET_ROOTFS_INITRAMFS=y" "$CFG"
check "written the way kconfig writes it" "# CONFIG_TARGET_ROOTFS_INITRAMFS is not set" "$CFG"
check "and seeded in that same form" "# CONFIG_TARGET_ROOTFS_INITRAMFS is not set" "$SEEDED"
check "nothing else was touched" "CONFIG_KERNEL_DEVTMPFS=y" "$CFG"

echo "== a symbol that is absent from .config"
CFG=$(mktemp); SEEDED=$(mktemp)
: > "$CFG"
set_cfg_off "CONFIG_TARGET_ROOTFS_INITRAMFS" >/dev/null
check "appended when missing" "# CONFIG_TARGET_ROOTFS_INITRAMFS is not set" "$CFG"

echo "== a symbol that is already off, applied twice"
CFG=$(mktemp); SEEDED=$(mktemp)
printf '# CONFIG_TARGET_ROOTFS_INITRAMFS is not set\n' > "$CFG"
set_cfg_off "CONFIG_TARGET_ROOTFS_INITRAMFS" >/dev/null
set_cfg_off "CONFIG_TARGET_ROOTFS_INITRAMFS" >/dev/null
count=$(grep -c 'CONFIG_TARGET_ROOTFS_INITRAMFS' "$CFG")
if [ "$count" = "1" ]; then
	echo "  ok   still exactly one line (idempotent)"
else
	echo "  FAIL duplicated: $count lines"; fails=$((fails + 1))
fi

echo "== set_cfg wins over an off line"
CFG=$(mktemp); SEEDED=$(mktemp)
printf '# CONFIG_TARGET_ROOTFS_INITRAMFS is not set\n' > "$CFG"
set_cfg "CONFIG_TARGET_ROOTFS_INITRAMFS" "y" >/dev/null
check "the off line became =y" "CONFIG_TARGET_ROOTFS_INITRAMFS=y" "$CFG"
check "and seeded as =y" "CONFIG_TARGET_ROOTFS_INITRAMFS=y" "$SEEDED"

echo "== set_cfg replaces rather than appends"
CFG=$(mktemp); SEEDED=$(mktemp)
printf 'CONFIG_TARGET_ROOTFS_INITRAMFS=n\n' > "$CFG"
set_cfg "CONFIG_TARGET_ROOTFS_INITRAMFS" "y" >/dev/null
count=$(grep -c 'CONFIG_TARGET_ROOTFS_INITRAMFS' "$CFG")
if [ "$count" = "1" ]; then
	echo "  ok   exactly one line"
else
	echo "  FAIL duplicated: $count lines"; fails=$((fails + 1))
fi

echo
echo "== the flags the documentation and CI actually pass"
# The whole option loop, extracted the same way, so a spelling that stops being
# accepted fails here instead of 20 seconds into a 2-3 hour CI run.  It has: the
# workflow passed -j"$(nproc)" (which arrives as -j4) while the parser only took
# `-j 4`, and the build died with "unknown option: -j4" -- yet the repository's own
# examples showed -j8 the whole time.
{
	sed -n '/^INITRAMFS=1$/,/^done$/p' scripts/build-firmware.sh
	echo 'printf "%s|%s|%s|%s|%s\n" "$JOBS" "$VARIANT" "$INITRAMFS" "$WITH_FEEDS" "$OWRT_ARG"'
} > "$WORK/parser.sh"
if [ ! -s "$WORK/parser.sh" ]; then
	echo "FAIL could not extract the option parser"; fails=$((fails + 1))
else
	NCPU=$(nproc 2>/dev/null || echo 4)
	expect_parse() { # expect_parse <label> <expected> <args...>
		label=$1; expected=$2; shift 2
		got=$(bash "$WORK/parser.sh" "$@" 2>/dev/null)
		if [ "$got" = "$expected" ]; then
			echo "  ok   $label"
		else
			echo "  FAIL $label: got '$got', expected '$expected'"
			fails=$((fails + 1))
		fi
	}
	expect_parse "-j4"            "4|full|1|1|"    -j4
	expect_parse "-j 4"           "4|full|1|1|"    -j 4
	expect_parse "--jobs 4"       "4|full|1|1|"    --jobs 4
	expect_parse "--jobs=4"       "4|full|1|1|"    --jobs=4
	expect_parse "--no-feeds"     "$NCPU|full|1|0|" --no-feeds
	expect_parse "tree + -j8 + --variant m2 + --no-initramfs" \
		"8|m2|0|1|/tree" /tree -j8 --variant m2 --no-initramfs
	if bash "$WORK/parser.sh" -jbogus >/dev/null 2>&1; then
		echo "  FAIL -jbogus was accepted as a job count"
		fails=$((fails + 1))
	else
		echo "  ok   -jbogus is refused"
	fi
fi

echo
if [ "$fails" -ne 0 ]; then
	echo "$fails check(s) FAILED"
	exit 1
fi
echo "ok: set_cfg / set_cfg_off and the option parser behave as the gate expects"
