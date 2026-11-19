#!/bin/sh
# Run ON THE QN10 as root: sh qn10-install-kernel.sh DIR [TAG]
# DIR holds one linux-image-*.deb and glymur-asus-ascent-qn10.dtb. TAG is the
# qcom-next tag of the build, for the boot entry title.
# Installs the kernel next to the existing ones (their entries stay) and
# makes the new boot entry the default.
set -eu
dir=$1
tag=${2:-}
deb='' n=0
for f in "$dir"/linux-image-*.deb; do
	case $f in *-dbg_*) continue ;; esac
	[ -f "$f" ] || continue
	deb=$f n=$((n + 1))
done
[ "$n" -eq 1 ] || { echo "error: $dir must hold exactly one linux-image package" >&2; exit 1; }
V=$(dpkg-deb -f "$deb" Package | sed 's/^linux-image-//')
esp=/boot/efi
mid=$(cat /etc/machine-id)

# kernel-install's 90-loaderentry looks up /etc/kernel/devicetree under
# /usr/lib/linux-image-$V; the QN10 tree is not in the kernel source, so place
# it first (dpkg leaves unowned files alone).
install -D -m 0644 "$dir/glymur-asus-ascent-qn10.dtb" \
	"/usr/lib/linux-image-$V/qcom/glymur-asus-ascent-qn10.dtb"
cat /etc/kernel/devicetree /etc/kernel/cmdline

# Ethernet: 7.4 uses the in-tree r8169, which needs this firmware file.
ls -l /usr/lib/firmware/rtl_nic/rtl8125bp-2.fw* 2>/dev/null ||
	echo "WARNING: rtl8125bp-2.fw missing; Ethernet may not come up on $V"

dpkg -i "$deb"

entry=$esp/loader/entries/$mid-$V.conf
[ -f "$entry" ] || { echo "error: kernel-install made no $entry" >&2; exit 1; }
sed -i "s/^title .*/title      Debian 13 QN10 kernel $V${tag:+ ($tag)}/" "$entry"
cat "$entry"
ls -l "$esp/$mid/$V/"

cp -p "$esp/loader/loader.conf" "$esp/loader/loader.conf.before-$V"
sed -i "s/^default .*/default $mid-$V.conf/" "$esp/loader/loader.conf"
grep -q '^timeout' "$esp/loader/loader.conf" || echo 'timeout 10' >>"$esp/loader/loader.conf"
cat "$esp/loader/loader.conf"
echo "done: reboot to try $V; pick an older entry from the menu to go back"
