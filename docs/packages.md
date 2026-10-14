# Prebuilt images and the apk package repository

Two different questions live in this document, and confusing them is the usual
reason somebody spends an afternoon on `invalid module format`:

* **Can I install a userspace package?** Yes, from OpenWrt's own generic
  `arm_cortex-a7` feeds. Measured on the board: a new userspace package
  installs, and the board still boots with SSH reachable.
  The arch string is worth stating because this document said
  `aarch64_cortex-a53` for a while: the `en7523` subtarget declares
  `CPU_TYPE:=cortex-a7` and the target builds 32-bit (`CONFIG_ARCH="arm"`), so the
  configuration seeded here resolves to `CONFIG_TARGET_ARCH_PACKAGES="arm_cortex-a7"`
  -- the kernel build directory is literally `target-arm_cortex-a7_musl_eabi` --
  and the board's own feed list in [wifi.md](wifi.md) section 4 names the same.
  `aarch64_cortex-a53` is a different architecture: apk refuses those packages
  here, the two are not interchangeable.
* **Can I install a kernel module?** Not from OpenWrt. This is the half the
  repository published by this project exists for.

## Why kernel modules are the problem

The `en7523` subtarget declares `FEATURES:=source-only`. OpenWrt's builders use
that to decide not to produce a `kmods/` directory for it, and kernel modules are
published per target *and per kernel build*:

```
bin/targets/<target>/<subtarget>/kmods/<kernel>-<hash>/packages.adb
```

No such directory exists for a target nobody builds images for. Userspace
packages do not have that constraint -- they depend on the CPU/ABI, not on the
kernel -- which is why the generic feeds work here and `kmod-*` does not.

The consequence, before this repository existed: every `kmod-*` an image wanted
had to be baked in at build time. That is still the rule for whatever the image
ships with (`scripts/packages.append`, `scripts/packages-m2.append`); what changes
is that a module can now also be added to a **running** board, as long as it is
built for the kernel that board is running.

## What is published, and where

| | |
|---|---|
| Images, Image Builder, SHA256SUMS | [GitHub Releases](https://github.com/realldz/econet-42x6-openwrt/releases), built and verified by CI |
| Kernel modules | the `gh-pages` branch, one directory per release tag |
| Userspace feeds | the same branch, only when a release was built with feeds enabled |

The branch looks like this:

```
<tag>/kmods/<kernel>-<hash>/packages.adb
<tag>/kmods/<kernel>-<hash>/*.apk
<tag>/packages/<arch>/<feed>/packages.adb      (only with feeds enabled)
<tag>/metadata.json                            which images these belong to
<tag>/install.md                               the commands, with the real path
releases.json                                  every published release
index.html                                     landing page
```

`<tag>` is the release tag, so the URL is versioned on purpose: a kernel module
only loads into the kernel it was built against.

## Installing a module

The exact directory name for a release is written in its release notes and in
`<tag>/install.md` -- do not guess it.

```sh
# Point apk at the repository for the release whose image the board is running.
echo 'https://realldz.github.io/econet-42x6-openwrt/<tag>/kmods/<kernel>' \
  > /etc/apk/repositories.d/42x6-kmods.list

apk update --allow-untrusted
apk search --allow-untrusted
apk add --allow-untrusted <package>
```

`uname -r` reports the kernel release the board runs, and on this image
`/lib/modules/` is `6.18.54`, so `uname -r` is `6.18.54`; the directory name
starts with that and the rest identifies the build. If they do not match, the
module is refused at load time rather than at install time.

### Proving it on the board

Two things can be wrong independently -- the repository may be unreachable, or the
module may not belong to the kernel the board is running -- and they fail
differently, so check them in that order:

```sh
uname -r                                     # must match the directory in the URL
apk list --installed | grep '^kmod-'         # what the image already carries

apk update --allow-untrusted                 # reachability and index, before installing
apk search --allow-untrusted | head

apk add --allow-untrusted kmod-<name>        # something the image does not carry
modprobe <name> && dmesg | tail
```

A module built for a different kernel installs and then refuses to load:

```
insmod: ERROR: could not insert module ...: Invalid module format
```

That is the expected result of pointing a board at the wrong release tag, and it is
the tag in the URL doing its job rather than a broken repository. It is also why
the modules are fetched *per release* instead of from one shared directory.

### If GitHub Pages is not enabled

apk does not need a web server, only a URL that serves the index, so the branch
is usable through the raw host:

```sh
echo 'https://raw.githubusercontent.com/realldz/econet-42x6-openwrt/gh-pages/<tag>/kmods/<kernel>' \
  > /etc/apk/repositories.d/42x6-kmods.list
```

### The packages are not signed

apk checks repository signatures; these are unsigned, which is what
`--allow-untrusted` switches off. The trust is therefore in TLS and in the
hosting, not in a key. That is a deliberate trade: signing would mean keeping a
private key in CI secrets for artifacts that are reproducible from the pinned
revision in [`scripts/pin.env`](../scripts/pin.env). If you would rather not
trust the download, build the module yourself against the same revision.

## What not to do

* **Do not run `apk upgrade`.** Measured: 12 installed packages in the snapshot
  are behind, one of them a `zlib` major-version change, which can break every
  binary linked against the older `zlib` -- including the SSH server you would
  need to repair it. Install one package at a time.
* **Do not point apk at another release's directory.** It resolves and downloads
  happily, then fails at load time with `invalid module format`, which names the
  module and not the mismatch.
* **Do not install a module built for another board**, even one with the same SoC
  and the same kernel version.

## Publishing a repository yourself, or from a fork

It is one script:

```bash
./scripts/publish-packages.sh openwrt --tag v0.2.0 --out pages [--with-feeds]
```

It *discovers* the layout of the finished build tree instead of assuming it. The
modules are looked for in `bin/targets/airoha/en7523/kmods/*/` first (the shape
OpenWrt's own builders publish) and then in `bin/targets/airoha/en7523/packages/`,
which is where a plain local build of this target leaves them: measured on a real
build of this board, that directory held 73 packages, among them
`kmod-xpon-6.18.54-r1.apk`. It refuses a tree with more than one kernel under it,
refuses to write a half-filled release directory, publishes whichever directory it
chose *whole* -- the index beside those packages lists every one of them, so
copying a subset would publish an index pointing at files that are not there -- and
writes `metadata.json`, `install.md`, `releases.json` and `index.html` beside the
packages. `--with-feeds` is off by default because the kernel modules are a few
megabytes and the full userspace set is hundreds: publish what somebody needs.

`tools/test_publish_packages.sh` exercises the failure paths and the generated
layout against a fake build tree -- both layouts, `kmods/<kernel>/` and
`packages/` -- and `lint.yml` runs it on every push.

In CI, `release.yml` calls it in the job that produced the sysupgrade image, only
after that image passed `tools/verify_image.py`, and the `pages` job pushes the
result to `gh-pages`. The branch keeps every past release on purpose: somebody
running an older image still needs the modules built for its kernel.

## Verified, and not

* `[hardware]` Userspace packages install from the generic feeds; `apk add` works;
  `apk upgrade` breaks the userland.
* The image's own kernel modules are the same packages it was built with, so
  publishing them does not change what the image contains.
* **The kmod repository has not been exercised on a board yet**: no release has
  been published. What is tested is the publisher itself -- its failure paths and
  both source layouts -- and the verification gate that runs before it in CI. The
  procedure above is what the first release has to pass, and until it does, the
  repository is `[not verified]` on hardware.
