#!/usr/bin/env bash
# Runs in a debian:trixie container inside a Firecracker microVM, started by
# qn10-kernel-autobuild.sh. Clones the qcom-next TAG and the patch repository,
# applies the patches, and builds Debian packages into /root/builds/out.
# Writes the stage it reached to /root/builds/status, so the host can tell a
# patch or build failure from a network fault.
#
# Environment: TAG, PATCH_REPO, PATCH_BRANCH, KERNEL_REPO, REV, JOBS.
# Input: /root/builds/config (the config of the running kernel).
set -euo pipefail
B=/root/builds
stage(){ echo "$1" >"$B/status"; echo "== $1"; }

stage setup
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
	build-essential bc bison flex libssl-dev libelf-dev libdw-dev dpkg-dev \
	debhelper rsync kmod cpio dwarves zstd python3 git ca-certificates >/dev/null

stage clone
git clone -q --depth=1 --branch "$TAG" "$KERNEL_REPO" "$B/src"
git clone -q --depth=1 --branch "$PATCH_BRANCH" "$PATCH_REPO" "$B/patches"
git -C "$B/patches" log -1 --format='%h %s' | tee "$B/patches.txt"

for p in "$B"/patches/*.patch; do
	stage "patch $(basename "$p")"
	git -C "$B/src" apply --verbose "$p"
done

stage build
cd "$B/src"
cp "$B/config" .config
scripts/config --set-str LOCALVERSION "-qn10" --disable LOCALVERSION_AUTO
make -s olddefconfig
version=$(make -s kernelversion)
make -j"$JOBS" KDEB_PKGVERSION="$version-${REV}qn10" bindeb-pkg

mkdir -p "$B/out"
mv "$B"/*.deb "$B/out/"
cp "$B/patches/qn10-install-kernel.sh" "$B/patches.txt" "$B/out/"
echo "$version" >"$B/out/version"
stage ok
