#!/bin/sh
# Run ON THE QN10 as the debian user: sh qn10-native-setup.sh [TAG]
# Sets up native kernel builds on the QN10 itself:
#   ~/kernel/src       qcom-next source at TAG with our patches applied
#   ~/kernel/patches   the patch series (copied from the Mac)
#   ~/kernel/build.sh  config from the running kernel + olddefconfig + debs
# Uses sudo only for apt-get.
set -eu
TAG=${1:-qcom-next-7.4-rc1-20261116}
K=$HOME/kernel
mkdir -p "$K"

echo "== build dependencies"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
	build-essential bc bison flex libssl-dev libelf-dev libdw-dev dpkg-dev \
	debhelper rsync kmod cpio dwarves zstd python3 git ccache >/dev/null
echo ok

if [ ! -d "$K/src/.git" ]; then
	echo "== clone $TAG"
	git clone -q --depth=1 --branch "$TAG" https://github.com/qualcomm-linux/kernel.git "$K/src"
	for p in "$K"/patches/*.patch; do
		echo "apply $(basename "$p")"
		git -C "$K/src" apply "$p"
	done
fi
git -C "$K/src" log -1 --format='source %h %s'
git -C "$K/src" diff --stat | tail -1
echo "== done; build with: sh ~/kernel/build.sh REV"
