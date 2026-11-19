#!/usr/bin/env bash
# Runs in a debian:trixie container inside a Firecracker microVM, started by
# qn10-kernel-autobuild.sh. Clones the qcom-next TAG and the patch repository,
# applies the patches, and builds Debian packages into /root/builds/out.
# Writes the stage it reached to /root/builds/status, so the host can tell a
# patch or build failure from a network fault.
#
# Also writes /root/builds/changes.txt, a summary of the Qualcomm commits that
# changed since OLD_TAG, the tag of the running kernel.
#
# Environment: TAG, OLD_TAG, PATCH_REPO, PATCH_BRANCH, KERNEL_REPO, REV, JOBS.
# Input: /root/builds/config (the config of the running kernel).
set -euo pipefail
B=/root/builds
stage(){ echo "$1" >"$B/status"; echo "== $1"; }

# qcom-next-<version>-<YYYYMMDD> is mainline v<version> plus Qualcomm commits.
base_of(){ local t=${1#qcom-next-}; echo "v${t%-*}"; }

# Compare the Qualcomm commits of OLD_TAG and TAG. Fetches about 4 months of
# history without file contents (about 80 MB), in its own repository.
changes(){
	local new=$TAG old=$OLD_TAG nb ob since r=$B/history
	nb=$(base_of "$new") ob=$(base_of "$old")
	since=$(date -d "${old##*-} -120 days" +%F)
	git init -q --bare "$r"
	git -C "$r" fetch -q --filter=blob:none --shallow-since="$since" "$KERNEL_REPO" \
		"refs/tags/$new:refs/tags/$new" "refs/tags/$old:refs/tags/$old" \
		"refs/tags/$nb:refs/tags/$nb" "refs/tags/$ob:refs/tags/$ob" || return 1
	git -C "$r" log --no-merges --format=%s "$nb..$new" | sort -u >"$B/new.txt"
	git -C "$r" log --no-merges --format=%s "$ob..$old" | sort -u >"$B/old.txt"
	sed -n 's#^+++ b/##p' "$B"/patches/*.patch | sort -u >"$B/paths.txt"

	echo "Changes from $old to $new"
	echo
	echo "Mainline base: $ob -> $nb"
	echo "Qualcomm commits on top of mainline: $(wc -l <"$B/old.txt") -> $(wc -l <"$B/new.txt")"
	echo "By subject: $(comm -23 "$B/new.txt" "$B/old.txt" | wc -l) new," \
		"$(comm -13 "$B/new.txt" "$B/old.txt" | wc -l) no longer carried (merged upstream or dropped)," \
		"$(comm -12 "$B/new.txt" "$B/old.txt" | wc -l) in both"
	echo
	echo "Qualcomm commits in $new that change files our patches change:"
	# shellcheck disable=SC2046 # one argument per path
	git -C "$r" log --no-merges --format='  %h %s' "$nb..$new" -- $(cat "$B/paths.txt")
	echo
	echo "New Qualcomm commits:"
	comm -23 "$B/new.txt" "$B/old.txt" | sed 's/^/  /'
	echo
	echo "Qualcomm commits no longer carried:"
	comm -13 "$B/new.txt" "$B/old.txt" | sed 's/^/  /'
}

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

stage changes
changes >"$B/changes.txt" 2>&1 || echo "The change summary failed, see above." >>"$B/changes.txt"

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
