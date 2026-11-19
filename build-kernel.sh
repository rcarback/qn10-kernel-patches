#!/bin/sh
# Build Debian packages of a qcom-next kernel for the QN10.
# Run as root inside the build VM:
#   orb -m qn10-build -u root env REV=N sh build-kernel.sh [TAG]   (REV: package revision, default 1)
# Base config: the packaged qcom-next 7.3 config from our boot-tested image,
# brought forward with olddefconfig. Local patches: ./*.patch.
# Writes only under $W; the image is mounted read-only to read its config.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TAG=${1:-qcom-next-7.4-rc1-20261116}
W=/home/carback1/qn10-build/kernel
IMG=/home/carback1/qn10-build/qcom-deb-images/disk-sdcard-qn10-v3.img
CONFIG_VER=7.3.0+qcom-next-20261030-gae2606baf50f
SRC=$W/$TAG

echo "== build dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq --no-install-recommends \
	bc bison flex libssl-dev libelf-dev libdw-dev dpkg-dev debhelper \
	rsync kmod cpio dwarves zstd python3 git >/dev/null

mkdir -p "$W"
base=$W/config-$CONFIG_VER
if [ ! -f "$base" ]; then
	echo "== base config from $IMG"
	m=$(mktemp -d)
	lo=$(losetup -f --show -r -o $((1064960 * 512)) "$IMG")
	mount -o ro "$lo" "$m"
	cp "$m/boot/config-$CONFIG_VER" "$base"
	umount "$m"
	losetup -d "$lo"
	rmdir "$m"
fi

if [ ! -d "$SRC" ]; then
	echo "== clone $TAG"
	git clone -q --depth=1 --branch "$TAG" https://github.com/qualcomm-linux/kernel.git "$SRC"
	for p in "$HERE"/*.patch; do
		[ -e "$p" ] || continue
		echo "apply $(basename "$p")"
		git -C "$SRC" apply --verbose "$p"
	done
fi
git -C "$SRC" log -1 --format='source %H %s'

echo "== configure"
cd "$SRC"
cp "$base" .config
# Packaged config points at Debian signing material that is not here.
scripts/config --set-str SYSTEM_TRUSTED_KEYS "" \
	--set-str SYSTEM_REVOCATION_KEYS "" \
	--set-str MODULE_SIG_KEY "certs/signing_key.pem" \
	--set-str LOCALVERSION "-qn10" \
	--disable LOCALVERSION_AUTO \
	--disable DEBUG_INFO_BTF \
	--enable DEBUG_INFO_NONE \
	--disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
	--disable DEBUG_INFO_DWARF5 \
	--enable HIDRAW \
	--module R8169
# R8169: the packaged kernel leaves it off and ships an out-of-tree r8169
# in a separate package; the in-tree driver supports the QN10's RTL8125BP.
scripts/kconfig/merge_config.sh -m .config "$HERE/qn10.config" >/dev/null
make -s olddefconfig
# olddefconfig drops an option whose dependencies are missing. Fail then.
grep "^CONFIG_" "$HERE/qn10.config" | while IFS= read -r opt; do
	grep -qxF "$opt" .config || { echo "config: $opt did not stick" >&2; exit 1; }
done
for s in SND_SOC_WCD9378_SDW QCOM_QSEECOM QCOM_QSEECOM_UEFISECAPP RTC_DRV_PM8XXX \
	PHY_QCOM_EDP DRM_MSM CLK_GLYMUR_DISPCC ATH12K NVME_SPEED_SWITCH HIDRAW R8169; do
	grep -E "^(# )?CONFIG_${s}[= ]" .config || echo "(CONFIG_$s not present)"
done

echo "== build"
make -j"$(nproc)" KDEB_PKGVERSION="$(make -s kernelversion)-${REV:-1}qn10" bindeb-pkg
ls -l "$W"/*.deb
sha256sum "$W"/*.deb
echo "== done"
