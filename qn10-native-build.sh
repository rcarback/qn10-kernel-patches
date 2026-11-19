#!/bin/sh
# Run ON THE QN10 as the debian user: sh ~/kernel/build.sh REV
# Builds Debian packages of the patched qcom-next tree in ~/kernel/src,
# starting from the running kernel's config. Output: ~/kernel/*.deb.
# Install with: sudo dpkg -i ~/kernel/linux-image-*-REVqn10_arm64.deb
# (the QN10 DTB must already be in /usr/lib/linux-image-<ver>/qcom/).
set -eu
REV=${1:?usage: build.sh REV}
K=$HOME/kernel
cd "$K/src"
cp "/boot/config-$(uname -r)" .config
scripts/config --set-str LOCALVERSION "-qn10" --disable LOCALVERSION_AUTO
scripts/kconfig/merge_config.sh -m .config "$K/patches/qn10.config" >/dev/null
make -s olddefconfig
# olddefconfig drops an option whose dependencies are missing. Fail then.
grep "^CONFIG_" "$K/patches/qn10.config" | while IFS= read -r opt; do
	grep -qxF "$opt" .config || { echo "config: $opt did not stick" >&2; exit 1; }
done
export CCACHE_DIR="$K/ccache"
make -j"$(nproc)" CC="ccache gcc" KDEB_PKGVERSION="$(make -s kernelversion)-${REV}qn10" bindeb-pkg
ls -l "$K"/linux-image-*-"${REV}"qn10_arm64.deb
