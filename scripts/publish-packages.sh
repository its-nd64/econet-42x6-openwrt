#!/usr/bin/env bash
#
# Assemble an apk package repository out of a finished OpenWrt build tree, ready
# to be published on a branch (gh-pages) and consumed by a board with `apk`.
#
#   ./scripts/publish-packages.sh <openwrt-tree> --tag v0.2.0 --out <dir>
#                                  [--with-feeds] [--base-url URL]
#
# Why this exists
# ---------------
# Kernel modules are the one thing this target cannot install from OpenWrt.
# target airoha/en7523 is FEATURES:=source-only, which is how OpenWrt's builders
# decide not to publish a package feed for it, and a module is built against one
# exact kernel.  Userspace packages are unaffected -- they depend on the CPU/ABI,
# not the kernel, so the generic aarch64_cortex-a53 feeds serve this board
# normally.
#
# So a module that is not already in the image has to come from a repository
# somebody built against that kernel, and this script writes one.
#
# The repository is published per release, under the release tag:
#
#   <out>/<tag>/kmods/<kernel>/packages.adb + *.apk     the target's packages
#   <out>/<tag>/packages/<arch>/<feed>/packages.adb     userspace feeds (opt-in)
#
# and the tag in the URL is part of the contract: a user must point apk at the
# directory that belongs to the image they are running.
#
# The layout is discovered rather than assumed, in two senses.  OpenWrt moved from
# opkg to apk on main, so the file names around it are not stable enough to
# hardcode; and the kernel modules do not live in the same place in every tree.
# OpenWrt's builders publish bin/targets/<target>/<subtarget>/kmods/<kernel>-.../,
# while a plain local build of THIS target leaves them in
# bin/targets/<target>/<subtarget>/packages/ next to the target's other packages
# (measured on a real build of this board: 73 packages, among them
# kmod-xpon-6.18.54-r1.apk, all under `packages/`).  An earlier version of this
# script required the kmods/ spelling and would have failed a two and a half hour
# CI run at the last step.
#
# Whichever directory is chosen is published whole, because the index in it
# describes every file beside it: copying a subset would publish an index that
# lists packages that are not there.
#
# Everything is validated before anything is copied: a release directory that is
# half-written (kmods present, feeds missing) is worse than no directory at all,
# because the URL in it looks usable.
#
# Userspace feeds are opt-in (--with-feeds) because that is where the size is:
# the target's own packages are a few megabytes, the whole package set is
# hundreds.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=pin.env
. "$HERE/pin.env"

PYTHON="${PYTHON:-python3}"

TAG=""
OUT=""
WITH_FEEDS=0
BASE_URL="https://realldz.github.io/econet-42x6-openwrt"
OWRT_ARG=""

while [ $# -gt 0 ]; do
	case "$1" in
		--tag)        TAG="${2:?--tag needs a value}"; shift ;;
		--out)        OUT="${2:?--out needs a directory}"; shift ;;
		--base-url)   BASE_URL="${2:?--base-url needs a URL}"; shift ;;
		--with-feeds) WITH_FEEDS=1 ;;
		-h|--help)    awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
		-*)           echo "!! unknown option: $1" >&2; exit 2 ;;
		*)            OWRT_ARG="$1" ;;
	esac
	shift
done

if [ -z "$OWRT_ARG" ] || [ -z "$TAG" ] || [ -z "$OUT" ]; then
	echo "usage: $0 <openwrt-tree> --tag TAG --out DIR [--with-feeds] [--base-url URL]" >&2
	exit 2
fi
OWRT=$(cd "$OWRT_ARG" && pwd)
OUT=$(mkdir -p "$OUT" && cd "$OUT" && pwd)
DEST="$OUT/$TAG"

BIN="$OWRT/$TARGET_BIN"
[ -d "$BIN" ] || { echo "!! no build output in $BIN" >&2; exit 1; }

shopt -s nullglob

# ---------------------------------------------------------------------------
# (1) Find the kernel modules -- the part that actually needs a repository
# ---------------------------------------------------------------------------
index_name() { # index_name <dir> -> the index file name, if the directory has one
	local cand
	for cand in packages.adb Packages; do
		if [ -f "$1/$cand" ]; then
			echo "$cand"
			return 0
		fi
	done
	return 1
}

KMOD_DIR=""
KMOD_PKGS=()   # everything in the chosen directory: the index describes all of it
KMOD_FILES=()  # the kernel modules among them

# Two kernels' worth of modules in the tree means a rebuild after a kernel bump.
# Publishing whichever directory the glob reaches first would serve modules for a
# kernel nobody is running.
KMOD_DIRS=("$BIN"/kmods/*/)
if [ ${#KMOD_DIRS[@]} -gt 1 ]; then
	echo "!! more than one kernel under $BIN/kmods: ${KMOD_DIRS[*]}" >&2
	echo "   publishing both would make the URL ambiguous, and publishing one of" >&2
	echo "   them may serve modules for a kernel nobody is running; remove the" >&2
	echo "   stale directory (the output of an earlier kernel) first." >&2
	exit 1
fi

for dir in "$BIN"/kmods/*/ "$BIN/packages/"; do
	[ -d "$dir" ] || continue
	index_name "$dir" >/dev/null || continue
	all=("$dir"*.apk "$dir"*.ipk)
	[ ${#all[@]} -gt 0 ] || continue
	# Everything in a kmods/ directory is a module.  A packages/ directory is a
	# mixed feed, so there the modules have to be named as modules; if none are,
	# this is not the directory that makes a module installable and we keep
	# looking rather than publish something that cannot do the job.
	case "$dir" in
		*/kmods/*) modules=("${all[@]}") ;;
		*)         modules=("$dir"kmod-*.apk "$dir"kmod-*.ipk) ;;
	esac
	[ ${#modules[@]} -gt 0 ] || continue
	KMOD_DIR="$dir"
	KMOD_PKGS=("${all[@]}")
	KMOD_FILES=("${modules[@]}")
	break
done

if [ -z "$KMOD_DIR" ]; then
	echo "!! no directory with a package index and kernel modules under $BIN" >&2
	echo "   looked at:" >&2
	printf '     %s\n' "$BIN"/kmods/*/ "$BIN/packages/" >&2
	echo "   contents of $BIN:" >&2
	ls -1 "$BIN" >&2
	echo "   If this tree puts its packages somewhere else again, teach this" >&2
	echo "   script the location instead of guessing from this listing." >&2
	exit 1
fi
KMOD_INDEX=$(index_name "$KMOD_DIR")

# The kernel version names the directory users point apk at, so it has to be
# right.  A kmods/<kernel>/ directory states it; a mixed packages/ directory only
# states it in the file names, kmod-<module>-<kernel>-r<release>.apk.
KMOD_NAME=""
LAYOUT="kmods/<kernel>/"
case "$KMOD_DIR" in
	*/kmods/*) KMOD_NAME=$(basename "$KMOD_DIR") ;;
esac
if [ -z "$KMOD_NAME" ]; then
	LAYOUT="packages/"
	VERSIONS=()
	for f in "${KMOD_FILES[@]}"; do
		base=$(basename "$f")
		base=${base%.apk}
		base=${base%.ipk}
		v=$(printf '%s\n' "$base" | sed -n 's/.*-\([0-9][0-9A-Za-z.~]*\)-r[0-9][0-9A-Za-z.]*$/\1/p')
		[ -n "$v" ] && VERSIONS+=("$v")
	done
	if [ ${#VERSIONS[@]} -eq 0 ]; then
		echo "!! cannot read a kernel version from the module file names in $KMOD_DIR" >&2
		printf '     %s\n' "${KMOD_FILES[@]:0:8}" >&2
		echo "   expected kmod-<module>-<kernel>-r<release>.apk" >&2
		exit 1
	fi
	UNIQ=$(printf '%s\n' "${VERSIONS[@]}" | sort -u)
	if [ "$(printf '%s\n' "$UNIQ" | wc -l)" -ne 1 ]; then
		echo "!! $KMOD_DIR holds kernel modules for more than one kernel:" >&2
		printf '     %s\n' $UNIQ >&2
		echo "   A module only loads into the kernel it was built against, so this" >&2
		echo "   directory cannot be published as one repository.  Build the tree" >&2
		echo "   from clean, or remove the modules of the kernel you do not want." >&2
		exit 1
	fi
	KMOD_NAME="$UNIQ"
fi
KMOD_SOURCE=${KMOD_DIR#"$OWRT"/}
# The directory keeps its trailing slash for globbing, but the path recorded in
# metadata.json should not.
KMOD_SOURCE=${KMOD_SOURCE%/}

# ---------------------------------------------------------------------------
# (2) Find the userspace feeds -- opt-in, because this is where the size is
# ---------------------------------------------------------------------------
ARCH=""
FEEDS=()
if [ "$WITH_FEEDS" = "1" ]; then
	ARCH_DIRS=("$OWRT/bin/packages"/*/)
	if [ ${#ARCH_DIRS[@]} -ne 1 ]; then
		echo "!! expected exactly one arch under $OWRT/bin/packages, found ${#ARCH_DIRS[@]}" >&2
		printf '   %s\n' "${ARCH_DIRS[@]}" >&2
		exit 1
	fi
	ARCH=$(basename "${ARCH_DIRS[0]}")
	for feed in "${ARCH_DIRS[0]}"*/; do
		# A feed is only worth publishing when it has an index and packages.
		feed_pkgs=("$feed"*.apk "$feed"*.ipk)
		[ -f "$feed/packages.adb" ] || [ -f "$feed/Packages" ] || continue
		[ ${#feed_pkgs[@]} -gt 0 ] || continue
		FEEDS+=("$(basename "$feed")")
	done
	if [ ${#FEEDS[@]} -eq 0 ]; then
		echo "!! --with-feeds was given but no feed under ${ARCH_DIRS[0]} has both an index and packages" >&2
		ls -1 "${ARCH_DIRS[0]}" >&2
		exit 1
	fi
fi

# ---------------------------------------------------------------------------
# (3) Copy
# ---------------------------------------------------------------------------
mkdir -p "$DEST/kmods/$KMOD_NAME"
cp -v "$KMOD_DIR"* "$DEST/kmods/$KMOD_NAME/" >&2
echo "==> ${#KMOD_FILES[@]} kernel module(s) for $KMOD_NAME, plus $(( ${#KMOD_PKGS[@]} - ${#KMOD_FILES[@]} )) other package(s), from $KMOD_SOURCE (index: $KMOD_INDEX)"

for feed in ${FEEDS[@]+"${FEEDS[@]}"}; do
	mkdir -p "$DEST/packages/$ARCH/$feed"
	cp -v "${OWRT}/bin/packages/$ARCH/$feed"/* "$DEST/packages/$ARCH/$feed/" >&2
done
if [ "$WITH_FEEDS" = "1" ]; then
	echo "==> feeds: ${#FEEDS[@]} feed(s) for arch $ARCH"
fi

# ---------------------------------------------------------------------------
# (4) Metadata: which image these modules belong to
# ---------------------------------------------------------------------------
IMAGES="[]"
if compgen -G "$BIN/*.bin" >/dev/null; then
	IMAGES=$(
		cd "$BIN"
		"$PYTHON" - <<'PY'
import glob, hashlib, json, os

out = []
for path in sorted(glob.glob("*.bin")):
	size = os.path.getsize(path)
	digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
	out.append({"file": path, "size": size, "sha256": digest})
print(json.dumps(out))
PY
	)
fi

"$PYTHON" - "$DEST/metadata.json" "$TAG" "$KMOD_NAME" "$ARCH" "${#FEEDS[@]}" "$KMOD_INDEX" "$IMAGES" \
	"$TARGET" "$SUBTARGET" "$OPENWRT_COMMIT" "$OPENWRT_DESCRIBE" "$KMOD_SOURCE" \
	"${#KMOD_FILES[@]}" "${#KMOD_PKGS[@]}" <<'PY'
import datetime, json, sys

(dest, tag, kmod, arch, feeds, index, images,
 target, subtarget, commit, describe, source, modules, packages) = sys.argv[1:15]
data = {
    "tag": tag,
    "target": target,
    "subtarget": subtarget,
    "openwrt_commit": commit,
    "openwrt_describe": describe,
    "kernel": kmod,
    "kmods": "kmods/%s/" % kmod,
    "index": index,
    # Where on the build tree this came from, because the directory name differs
    # between a builder's tree (kmods/<kernel>-<release>-<magic>/) and a local one
    # (packages/, modules and the target's other packages side by side).
    "source_dir": source,
    "kernel_modules": int(modules),
    "packages_published": int(packages),
    "userspace_arch": arch,
    "userspace_feeds": int(feeds),
    "images": json.loads(images),
    "published_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
json.dump(data, open(dest, "w"), indent=2, sort_keys=True)
print(json.dumps(data, indent=2, sort_keys=True))
PY
# ---------------------------------------------------------------------------
# (5) Landing page, install note, and the index of releases
#
# install.md is generated rather than hand-written because the URL contains the
# tag, and a stale tag in the instructions is exactly how somebody installs a
# module built for a different kernel.
# ---------------------------------------------------------------------------
SITE="$BASE_URL"
RAW="https://raw.githubusercontent.com/${GITHUB_REPOSITORY:-realldz/econet-42x6-openwrt}/gh-pages"

cat > "$DEST/install.md" <<EOF
# Packages for $TAG

Built from OpenWrt \`$OPENWRT_COMMIT\` ($OPENWRT_DESCRIBE), kernel \`$KMOD_NAME\`,
taken from \`$KMOD_SOURCE\` on the build tree.

That directory is published whole: it holds the kernel modules for this kernel
(${#KMOD_FILES[@]} of them) and the rest of this target's packages, and \`$KMOD_INDEX\`
lists all of them.  OpenWrt itself publishes no feed for this board -- the target
is \`source-only\` -- which is why the modules have to come from here.

**The URL contains the release tag on purpose.**  A kernel module only loads into
the kernel it was built against, so these packages belong to the images published
in the \`$TAG\` release, and to no other release.

On the board:

\`\`\`sh
# 1. Point apk at this release's repository.
echo '${SITE}/$TAG/kmods/$KMOD_NAME' > /etc/apk/repositories.d/42x6-kmods.list

# 2. The packages are not signed, so apk must be told to accept them.
apk update --allow-untrusted
apk add --allow-untrusted <package>

# 3. Check what is available.
apk search --allow-untrusted
\`\`\`

If GitHub Pages is not serving this branch, the same tree is reachable from the
raw host, which apk handles just as well:

\`\`\`sh
echo '${RAW}/$TAG/kmods/$KMOD_NAME' > /etc/apk/repositories.d/42x6-kmods.list
\`\`\`

The signed-off alternative is to run it once per boot from a console instead of
editing the repository list:

\`\`\`sh
apk add --allow-untrusted --repository '${SITE}/$TAG/kmods/$KMOD_NAME' <package>
\`\`\`

## Two things that will waste your afternoon

* **\`apk upgrade\` is not safe on this board.**  Several packages in the OpenWrt
  snapshot are built against a different zlib ABI than the image carries.  Install
  one package at a time and reboot afterwards if anything looks wrong.
* **A module that refuses to load with \`invalid module format\` is from the wrong
  release.**  Check \`uname -r\` against the kernel listed above before assuming
  the module is broken.
EOF

"$PYTHON" - "$OUT/releases.json" "$DEST/metadata.json" <<'PY'
import json, os, sys

path, meta_path = sys.argv[1], sys.argv[2]
meta = json.load(open(meta_path))

entries = []
if os.path.exists(path):
    try:
        entries = json.load(open(path))
    except ValueError:
        entries = []

entries = [e for e in entries if e.get("tag") != meta["tag"]]
entries.insert(0, meta)
json.dump(entries, open(path, "w"), indent=2, sort_keys=True)
print("%d release(s) indexed" % len(entries))
PY

# The landing page points at releases.json's first entry, not at the tag of this
# run: rebuilding an older release must not make that page claim it is the newest.
NEWEST=$("$PYTHON" - "$OUT/releases.json" <<'PY'
import json, sys

print(json.load(open(sys.argv[1]))[0]["tag"])
PY
)

cat > "$OUT/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>econet-42x6-openwrt package repository</title>
<style>
 body { font: 16px/1.6 system-ui, sans-serif; max-width: 46rem; margin: 3rem auto; padding: 0 1rem; }
 code, pre { background: #f4f4f4; }
 pre { padding: .75rem; overflow-x: auto; }
</style>
</head>
<body>
<h1>Packages for the Econet vGP-42X6V1</h1>
<p>
 OpenWrt's <code>airoha/en7523</code> target is <code>source-only</code>, so
 OpenWrt publishes no package feed for this board and a kernel module cannot be
 installed from downloads.openwrt.org.  This branch carries a repository per
 release instead, holding the target's own packages and the kernel modules built
 against that release's kernel.  Userspace packages are unaffected: they come
 from the generic <code>aarch64_cortex-a53</code> feeds as usual.
</p>
<p><a href="releases.json">releases.json</a> lists every published release with
 its kernel and the sha256 of its images.</p>
<p>Most recently built: <a href="$NEWEST/install.md">$NEWEST</a>.</p>
<p><strong>A module only loads into the kernel it was built against.</strong>
 Match the release tag in the URL to the image you are running.</p>
</body>
</html>
EOF

touch "$OUT/.nojekyll"

echo
echo "==> Repository written to $DEST"
echo "    base URL   $SITE/$TAG/kmods/$KMOD_NAME"
echo "    packages   $(find "$DEST" \( -name '*.apk' -o -name '*.ipk' \) | wc -l)"
echo "    size       $(du -sh "$DEST" | cut -f1)"
