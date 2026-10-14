#!/usr/bin/env bash
#
# Configure and build OpenWrt for the Econet vG vGP-42X6V1 (Airoha EN7523).
#
#   ./scripts/build-firmware.sh /path/to/openwrt [options]
#
# Options:
#   --initramfs        also emit *-initramfs-kernel.bin        (default)
#   --no-initramfs     do not
#   --debug-kmods      install kmod-pciedbg + kmod-ringwatch into the image
#   --variant m2|full  which package set to seed               (default: full)
#                        m2   Ethernet + Wi-Fi + LuCI + apk only.  This is what a
#                             release meant for someone else's unit should be: it
#                             carries no driver that needs the per-unit laser
#                             (BOB) calibration blob.
#                        full m2 + optical frontend + xPON + OMCI.  Only useful
#                             on a unit whose BOB blob you have extracted from its
#                             own factory partition -- see docs/pon-port.md.
#   --packages FILE    seed FILE instead of the variant's own list
#   --no-packages      do not seed any package list into .config
#   --no-feeds         do not run ./scripts/feeds update/install
#   --with-pon         apply the stage 2 xPON patches (NOT functional yet)
#   --mt76-debug       also apply the diagnostic mt76 patch (never ship this)
#   --imagebuilder     additionally produce the self-contained Image Builder
#   --no-apply         skip apply-overlay.sh (assume the overlay is already in)
#   -j N, --jobs N     build parallelism (default: number of CPUs)
#   -h, --help         this text
#
# Run this on Linux (or inside the Docker/WSL environment described in
# docs/building.md).  OpenWrt cannot be built on Windows itself.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=pin.env
. "$HERE/pin.env"

INITRAMFS=1
DEBUG_KMODS=0
WITH_PON=0
WITH_PACKAGES=1
WITH_FEEDS=1
MT76_DEBUG=0
IMAGEBUILDER=0
DO_APPLY=1
VARIANT=full
PKGS_FILE=""
JOBS=$(nproc 2>/dev/null || echo 4)
OWRT_ARG=""

while [ $# -gt 0 ]; do
	case "$1" in
		--initramfs)    INITRAMFS=1 ;;
		--no-initramfs) INITRAMFS=0 ;;
		--debug-kmods)  DEBUG_KMODS=1 ;;
		--no-packages)  WITH_PACKAGES=0 ;;
		--no-feeds)     WITH_FEEDS=0 ;;
		--variant)      VARIANT="${2:?--variant needs m2 or full}"; shift ;;
		--packages)     PKGS_FILE="${2:?--packages needs a file}"; shift ;;
		--with-pon)     WITH_PON=1 ;;
		--mt76-debug)   MT76_DEBUG=1 ;;
		--imagebuilder) IMAGEBUILDER=1 ;;
		--no-apply)     DO_APPLY=0 ;;
		-j|--jobs)      JOBS="${2:?--jobs needs a number}"; shift ;;
		-h|--help)      awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
		-*)             echo "!! unknown option: $1" >&2; exit 2 ;;
		*)              OWRT_ARG="$1" ;;
	esac
	shift
done

if [ -z "$OWRT_ARG" ]; then
	echo "usage: $0 <openwrt-tree> [options]   (see --help)" >&2
	exit 2
fi
OWRT=$(cd "$OWRT_ARG" && pwd)

case "$VARIANT" in
	m2|full) ;;
	*) echo "!! --variant must be m2 or full, not '$VARIANT'" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# (1) Board support into the tree
# ---------------------------------------------------------------------------
if [ "$DO_APPLY" = "1" ]; then
	PON_FLAG=""
	[ "$WITH_PON" = "1" ] && PON_FLAG="--with-pon"
	MT76_DBG_FLAG=""
	[ "$MT76_DEBUG" = "1" ] && MT76_DBG_FLAG="--with-mt76-debug"
	# shellcheck disable=SC2086
	"$HERE/apply-overlay.sh" "$OWRT" $PON_FLAG $MT76_DBG_FLAG
	echo
else
	echo "==> --no-apply: assuming board support is already in $OWRT"
fi

# ---------------------------------------------------------------------------
# (2) Feeds
#
# A fresh clone of OpenWrt has no feeds/ directory at all, and everything this
# board wants beyond the bare system -- LuCI, the AP daemon, iperf3, i2c-tools --
# lives in one of them.  Left alone, `make defconfig` drops CONFIG_PACKAGE_luci
# without complaining and the image comes out with no web UI at all; the gate
# after defconfig below exists to catch exactly that.  Measured on this board's
# own tree before feeds were installed: feeds/ held only `base`,
# `grep -E '^CONFIG_FEED_' .config` was empty, and feeds/luci did not exist, so
# LuCI could not be enabled at all.
#
# The feeds follow their own branch heads rather than the revision pinned in
# pin.env, so a rebuild months later picks up newer feed packages.  The revisions
# actually used are printed below and belong in any bug report.
# ---------------------------------------------------------------------------
if [ "$WITH_FEEDS" = "1" ]; then
	if [ -d "$OWRT/feeds/luci" ] && [ -d "$OWRT/package/feeds/luci" ]; then
		echo "==> Feeds already installed, leaving them alone"
	else
		echo "==> ./scripts/feeds update -a && ./scripts/feeds install -a"
		( cd "$OWRT" && ./scripts/feeds update -a && ./scripts/feeds install -a )
	fi
	if [ -d "$OWRT/feeds" ]; then
		echo "    feed revisions in use:"
		for f in "$OWRT"/feeds/*/; do
			[ -d "$f/.git" ] || continue
			printf '      %-12s %s\n' "$(basename "$f")" \
				"$(git -C "$f" log -1 --format='%h %ad' --date=short 2>/dev/null || echo '?')"
		done
	fi
	echo
else
	echo "==> --no-feeds: not touching $OWRT/feeds"
	echo
fi

# ---------------------------------------------------------------------------
# (3) Seed .config
#
# set_cfg() replaces an existing assignment, un-comments an existing
# "# CONFIG_X is not set" line, or appends.  Appending blindly would leave
# duplicate keys behind, and in that case the outcome depends on whichever line
# kconfig reads last.
# ---------------------------------------------------------------------------
CFG="$OWRT/.config"
touch "$CFG"

# Every symbol this script seeds is recorded, so that after `make defconfig`
# the list can be re-checked: defconfig drops a symbol whose dependencies are
# not available, and a missing wpad or luci is easy to mistake for a broken
# driver later.  See docs/building.md.
SEEDED=$(mktemp)
trap 'rm -f "$SEEDED"' EXIT

set_cfg() {
	local key="$1" val="$2"
	if grep -q "^${key}=" "$CFG"; then
		sed -i "s|^${key}=.*|${key}=${val}|" "$CFG"
	elif grep -q "^# ${key} is not set" "$CFG"; then
		sed -i "s|^# ${key} is not set|${key}=${val}|" "$CFG"
	else
		printf '%s=%s\n' "$key" "$val" >> "$CFG"
	fi
	printf '%s=%s\n' "$key" "$val" >> "$SEEDED"
	echo "    ${key}=${val}"
}

# Turn a bool off, in the spelling kconfig itself uses.  `CONFIG_FOO=n` is valid
# input but `make defconfig` rewrites it to `# CONFIG_FOO is not set`, so that is
# what has to be written here and what the check further down has to look for --
# seeding `=n` would make the symbol look like it never survived.
set_cfg_off() {
	local key="$1"
	if grep -q "^${key}=" "$CFG"; then
		sed -i "s|^${key}=.*|# ${key} is not set|" "$CFG"
	elif ! grep -q "^# ${key} is not set" "$CFG"; then
		printf '# %s is not set\n' "$key" >> "$CFG"
	fi
	printf '# %s is not set\n' "$key" >> "$SEEDED"
	echo "    # ${key} is not set"
}

echo "==> Seeding $CFG"
set_cfg "CONFIG_TARGET_${TARGET}" "y"
set_cfg "CONFIG_TARGET_${TARGET}_${SUBTARGET}" "y"
set_cfg "CONFIG_TARGET_${TARGET}_${SUBTARGET}_DEVICE_${DEVICE_PROFILE}" "y"
set_cfg "CONFIG_TARGET_ROOTFS_SQUASHFS" "y"

if [ "$INITRAMFS" = "1" ]; then
	# Produces *-initramfs-kernel.bin, which is what the UART/YMODEM RAM-boot
	# procedure in docs/booting.md loads.  See "M1" in docs/status.md.
	# Caveat: with this on, the sysupgrade image can inherit a kernel with the
	# initramfs embedded in it (MEASURED 14.4 MB instead of 9.4 MB).  The
	# post-build check below warns about it; build with --no-initramfs when you
	# only want the persistent image.
	set_cfg "CONFIG_TARGET_ROOTFS_INITRAMFS" "y"
else
	# Clear it actively rather than merely not setting it.  An earlier --initramfs
	# build leaves `CONFIG_TARGET_ROOTFS_INITRAMFS=y` in .config, defconfig keeps
	# it, and the update-sysupgrade image then carries a kernel with the initramfs
	# embedded in it: MEASURED 12,058,913 B with the squashfs at 0x760000 against
	# 9,437,473 B at 0x3A0000.  Not setting the symbol is how that image was
	# produced, and docs/sysupgrade.md recorded the hole without closing it.
	#
	# CONFIG_TARGET_INITRAMFS_COMPRESSION_NONE does not need clearing with it:
	# that option only decides how an initramfs is compressed once one is being
	# embedded at all, and it is what turned the 12.0 MB case into 14.4 MB.
	set_cfg_off "CONFIG_TARGET_ROOTFS_INITRAMFS"
fi

if [ "$DEBUG_KMODS" = "1" ]; then
	# Diagnostic only.  kmod-ringwatch reads MT7916 WFDMA registers; it guards
	# its BAR0 access behind PCI_COMMAND.MEMORY because reading BAR0 while
	# Memory Space is off hangs the SoC irrecoverably.  See docs/pcie-root-cause.md.
	set_cfg "CONFIG_PACKAGE_kmod-pciedbg" "y"
	set_cfg "CONFIG_PACKAGE_kmod-ringwatch" "y"
fi

if [ "$IMAGEBUILDER" = "1" ]; then
	set_cfg "CONFIG_IB" "y"
	# Mandatory here: the airoha target is FEATURES:=source-only, so there are
	# no official package repositories for airoha/en7523 to fetch from.  Without
	# standalone the resulting Image Builder cannot resolve even kmod-mt7915e.
	set_cfg "CONFIG_IB_STANDALONE" "y"
fi

# ---------------------------------------------------------------------------
# (2b) Kernel-level .config symbols this board needs
#
# devtmpfs: OpenWrt deliberately does not use it, but MTD registers its devices
# during kernel init -- before procd exists -- so the uevent is lost and no
# /dev/mtd* node is ever created.  Without devtmpfs the kernel can have
# CONFIG_MTD_BLOCK=y and still expose nothing to flash from, which makes
# sysupgrade impossible.  See docs/sysupgrade.md.
# ---------------------------------------------------------------------------
set_cfg "CONFIG_KERNEL_DEVTMPFS" "y"
set_cfg "CONFIG_KERNEL_DEVTMPFS_MOUNT" "y"

# ---------------------------------------------------------------------------
# (2c) Packages
#
# The target is source-only, so anything the image needs must be selected at
# build time.  Two lists: scripts/packages.append (variant full) carries the
# optical + xPON + OMCI stack, scripts/packages-m2.append (variant m2, the one
# published as a release asset) stops at Ethernet + Wi-Fi + LuCI + apk.
# ---------------------------------------------------------------------------
if [ "$WITH_PACKAGES" = "1" ]; then
	if [ -z "$PKGS_FILE" ]; then
		case "$VARIANT" in
			m2)   PKGS_FILE="$HERE/packages-m2.append" ;;
			full) PKGS_FILE="$HERE/packages.append" ;;
		esac
	fi
	if [ ! -f "$PKGS_FILE" ]; then
		echo "!! $PKGS_FILE is missing" >&2
		exit 1
	fi
	echo "==> Seeding packages from $(basename "$PKGS_FILE") (variant $VARIANT)"
	while IFS= read -r line; do
		case "$line" in
			CONFIG_*=*) ;;
			*) continue ;;
		esac
		set_cfg "${line%%=*}" "${line#*=}"
	done < "$PKGS_FILE"
fi

# ---------------------------------------------------------------------------
# (4) Build
# ---------------------------------------------------------------------------
echo
echo "==> make defconfig"
( cd "$OWRT" && make defconfig )

echo
echo "==> Verifying the seeded symbols survived defconfig"
MISSING=0
while IFS= read -r want; do
	[ -n "$want" ] || continue
	if ! grep -qx "$want" "$CFG"; then
		echo "    MISSING  $want" >&2
		MISSING=$((MISSING + 1))
	fi
done < "$SEEDED"
if [ "$MISSING" -ne 0 ]; then
	cat >&2 <<'EOF'

!! Seeded symbol(s) did not survive make defconfig.

   defconfig drops a symbol whose dependencies are not available in this tree,
   and the usual reason is a feed that is not enabled or a package name that no
   longer exists.  Building anyway produces an image that is silently missing
   files (no AP daemon, no web UI), which is much harder to diagnose than a
   failure here.  Fix the symbol, or pass --no-packages if you really want the
   bare image.
EOF
	exit 1
fi
echo "    all $(grep -c . "$SEEDED") symbol(s) present"

echo
echo "==> make -j$JOBS"
( cd "$OWRT" && make -j"$JOBS" )

# ---------------------------------------------------------------------------
# (5) Report
# ---------------------------------------------------------------------------
echo
echo "==> Artifacts in $TARGET_BIN"
BIN="$OWRT/$TARGET_BIN"
if [ -d "$BIN" ]; then
	ls -l "$BIN"/*.bin 2>/dev/null || echo "    (no .bin files?)"
	if [ "$IMAGEBUILDER" = "1" ]; then
		ls -l "$BIN"/openwrt-imagebuilder-*.tar.zst 2>/dev/null \
			|| echo "    (no Image Builder tarball found -- check CONFIG_IB)"
	fi
else
	echo "!! $BIN does not exist -- the build did not produce target output" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# (5b) Sanity-check the sysupgrade image
#
# The persistent image must carry the PLAIN kernel.  When the same tree also
# builds an initramfs image (--initramfs, on by default), the kernel can end up
# with the initramfs cpio embedded in it, and the sysupgrade image inherits that:
# MEASURED 14,418,209 B with the squashfs at 0x880000, and a second one at
# 12,058,913 B with the squashfs at 0x760000, instead of 9,437,473 B with the
# squashfs at 0x3A0000.  The two kernel Images of that build had the same md5,
# which is what identifies it.
#
# --no-initramfs now clears CONFIG_TARGET_ROOTFS_INITRAMFS instead of only
# leaving it alone, so an inflated image here is no longer the flag's doing: it
# means the kernel was not actually rebuilt (an incremental build that kept a
# stale arch/arm/boot/Image), or that the tree carries an initramfs of its own
# under target/linux.  Both are worth stopping for.
#
# What the check measures: `mtdsplit_fit` derives the kernel partition as
# round_up(FIT totalsize, erase block) and then finds the rootfs by scanning for
# a filesystem magic *after* the FIT, so the squashfs offset is exactly
# round_up(totalsize) -- 0x3A0000 for a clean build here.  An offset far past
# that means the FIT itself grew, i.e. the kernel carries the initramfs.
# Why it matters: the image is much larger than it needs to be, and such a
# kernel boots its own embedded rootfs rather than the flash rootfs, so nothing
# persists across a reboot [not verified on this board, docs/sysupgrade.md].
# ---------------------------------------------------------------------------
# The gate itself lives in tools/verify_image.py, so the same code runs here
# and in CI.  --warn-only is deliberate: building with --initramfs (on by
# default) legitimately produces an image whose squashfs sits past the kernel
# partition, and that is a development artifact, not a build failure.  CI runs
# the same tool without --warn-only, so such an image is never published.
if command -v python3 >/dev/null 2>&1; then
	echo
	echo "==> Checking the sysupgrade image(s)"
	IMGS=("$BIN"/*-sysupgrade.bin)
	if [ -e "${IMGS[0]}" ]; then
		python3 "$REPO/tools/verify_image.py" --warn-only "${IMGS[@]}"
	else
		echo "    (no sysupgrade image produced)"
	fi
fi

cat <<EOF

==> Which artifact is which

  *-initramfs-kernel.bin   RAM-boot over UART/YMODEM, nothing is written to
                           flash.  This is the safe way to try a build.
  *-sysupgrade.bin         the persistent image; belongs in slot B
                           (mtd3, "tclinux_slave").

==> Verify before flashing

  python3 $REPO/tools/verify_build.py <image>    # FIT load/entry vs _text
  python3 $REPO/tools/verify_image.py <image>    # rootfs fits the kernel partition

verify_build.py checks that the FIT load/entry address is 0x80208000.  Get this
wrong and the kernel deadloops in head.S before it can print anything, leaving
the UART completely silent with no diagnostic.  See docs/booting.md.

verify_image.py is the flash gate for a sysupgrade image: mtdsplit_fit derives
the kernel partition from the FIT totalsize, so an image whose squashfs starts
past mtd4 (0x3A0000) cannot be split correctly by sysupgrade.  CI fails on it; a
local build only warns, because --initramfs is on by default here.  See
docs/sysupgrade.md.
EOF
