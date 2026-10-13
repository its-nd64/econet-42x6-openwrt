#!/bin/sh
# ---------------------------------------------------------------------------
# apply-omci.sh -- copy the two userspace OMCI packages into an OpenWrt tree
# AND synchronise the UAPI header.
#
# WHY THIS SCRIPT EXISTS (measured 2026-10-11, see docs/pon-port.md section 16):
#   The vendor package `omci-agent` bundles its own `include/linux/omci.h`, and
#   that copy is version **13** while the kernel this target builds is version
#   **14** (the header comes from the xPON source overlay into
#   target/linux/airoha/files/include/uapi/linux/omci.h, and
#   net/xpon/omci/core.c uses `.version = OMCI_GENL_VERSION`).
#   The measured consequence on the board (img31) was
#   `ubus call omci.agent family` -> `compatible: false` (kernel 14 / client
#   13), and every other method (`status`, `config_list`, `class_list`,
#   `mib_*`) failed with `Unknown error`.
#
#   The v13 -> v14 delta is +26/-1 lines: the version define, plus
#   `OMCI_ATTR_ONU_TYPE` inserted at the END of `enum omci_attr` (so no
#   attribute number moves), plus `enum omci_onu_type` and
#   `OMCI_CONFIG_SOURCE_SYSFS`.  The ABI is therefore compatible; only the
#   version number sent to the kernel was wrong.
#
#   The durable fix: pin ONE canonical copy in this repository
#   (omci/uapi/linux/omci.h), overwrite the vendored copy every time the
#   packages are copied in, and HARD FAIL if the kernel tree currently holds a
#   different one -- so a mismatched pair can never be built again.
# ---------------------------------------------------------------------------
set -e

OWRT="${1:-/root/openwrt}"
HERE=$(cd "$(dirname "$0")" && pwd)
CANON="$HERE/uapi/linux/omci.h"
DEST="$OWRT/package/utils/airoha"

[ -d "$OWRT" ] || { echo "!! not an OpenWrt tree: $OWRT"; exit 1; }
[ -f "$CANON" ] || { echo "!! canonical UAPI header missing: $CANON"; exit 1; }

_ver() { awk '/^#define OMCI_GENL_VERSION/{print $3}' "$1" 2>/dev/null; }
_md5() { md5sum "$1" 2>/dev/null | cut -c1-32; }

echo "==> canonical UAPI: $CANON"
echo "    OMCI_GENL_VERSION=$(_ver "$CANON")  md5=$(_md5 "$CANON")  ($(stat -c %s "$CANON") B)"

# ---------------------------------------------------------------------------
# (1) Copy the two packages into the tree.  Modes MUST be normalised: `cp -a`
#     from a Windows mount yields 0777 for every file, and that mode travels
#     into the .apk (luci.mk keeps it with $(CP)); for
#     /usr/share/rpcd/ucode/* rpcd then SILENTLY SKIPS a world-writable
#     script, so the whole page dies while the build still reports success.
# ---------------------------------------------------------------------------
mkdir -p "$DEST"
for p in omci-agent luci-app-omci; do
	[ -d "$HERE/packages/$p" ] || { echo "!! missing package $HERE/packages/$p"; exit 1; }
	rm -rf "$DEST/$p"
	cp -a "$HERE/packages/$p" "$DEST/$p"
	find "$DEST/$p" -type d -exec chmod 755 {} +
	find "$DEST/$p" -type f -exec chmod 644 {} +
	echo "==> $p -> $DEST/$p  (modes normalised to 755/644)"
done

# ---------------------------------------------------------------------------
# (2) Overwrite the vendored UAPI copy with this repository's canonical one
# ---------------------------------------------------------------------------
VEND="$DEST/omci-agent/src/include/linux/omci.h"
if [ -f "$VEND" ]; then
	_before=$(_ver "$VEND")
	cp "$CANON" "$VEND"
	echo "==> UAPI for omci-agent: $VEND"
	echo "    was: OMCI_GENL_VERSION=$_before  ->  now: $(_ver "$VEND")  md5=$(_md5 "$VEND")"
else
	echo "!! $VEND not found -- the omci-agent package is missing its UAPI header"; exit 1
fi

# hard gate: a world-writable ucode script is skipped by rpcd
_puc="$DEST/omci-agent/files/usr/share/rpcd/ucode/omci.agent"
if [ -e "$_puc" ]; then
	case "$(stat -c '%a' "$_puc")" in
		*[2367]) echo "!! $_puc mode $(stat -c '%a' "$_puc") -- rpcd will SKIP this script"; exit 1 ;;
		*) echo "    omci.agent mode $(stat -c '%a' "$_puc") (not world-writable -- rpcd will load it)" ;;
	esac
fi

# ---------------------------------------------------------------------------
# (3) GATE: if the prepared kernel tree already carries a UAPI header that
#     differs from the canonical one, stop now rather than build a mismatched
#     pair.  To fix: cp <kernel tree>/include/uapi/linux/omci.h
#     omci/uapi/linux/omci.h, review the delta and commit it -- then rebuild
#     BOTH sides (kernel and omci-agent).
# ---------------------------------------------------------------------------
KHEAD=$(ls -d "$OWRT"/build_dir/target-*/linux-airoha_en7523/linux-*/include/uapi/linux/omci.h 2>/dev/null | head -1)
if [ -n "$KHEAD" ]; then
	echo "==> comparing against the kernel tree: $KHEAD"
	echo "    kernel: OMCI_GENL_VERSION=$(_ver "$KHEAD")  md5=$(_md5 "$KHEAD")"
	if cmp -s "$CANON" "$KHEAD"; then
		echo "    MATCHES the canonical copy (byte-for-byte) -- userspace/kernel UAPI in sync"
	else
		echo "!! UAPI MISMATCH: the repository copy differs from the kernel tree header."
		echo "   repo  : $(_ver "$CANON")  $(_md5 "$CANON")"
		echo "   kernel: $(_ver "$KHEAD")  $(_md5 "$KHEAD")"
		echo "   Fix: cp \"$KHEAD\" \"$CANON\"  then rebuild BOTH kernel and omci-agent."
		exit 1
	fi
else
	echo "==> (no prepared kernel tree in build_dir -- skipping the cross-check;"
	echo "     the first build creates it, so re-run this script after prepare)"
fi

echo "==> OMCI sources done. Build with: make package/utils/airoha/omci-agent/compile"
