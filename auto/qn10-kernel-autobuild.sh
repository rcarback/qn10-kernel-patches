#!/usr/bin/env bash
# Run ON THE QN10 as the gitlab-runner user (qn10-kernel-autobuild.service).
# When qualcomm-linux/kernel has a qcom-next tag newer than KERNEL_TAG, build
# it with the patches from this repository in a Firecracker microVM, through
# the CI runner's custom executor scripts. build-in-vm.sh does the build in a
# debian:trixie container. Mails "ready to install", or the stage that failed
# with the tail of the log. Each tag gets one attempt, unless the attempt
# stopped at a network fault. Installing stays a manual step.
#
# Settings: /etc/default/qn10-kernel-autobuild
#   KERNEL_TAG    qcom-next tag of the running kernel (set it after each install)
#   MAILTO        recipient (default root)
#   PATCH_BRANCH  branch of the patch repository (default main)
#
# REBUILD=1 in the environment builds the tag of the running kernel again, for
# example after a change to qn10.config. The package revision then gets a time
# suffix, so that it sorts after the installed package:
#   sudo -u gitlab-runner env REBUILD=1 /usr/local/sbin/qn10-kernel-autobuild
set -euo pipefail

CONF=/etc/default/qn10-kernel-autobuild
KERNEL_TAG=
REBUILD=${REBUILD:-0}
MAILTO=root
KERNEL_REPO=https://github.com/qualcomm-linux/kernel.git
PATCH_REPO=https://github.com/rcarback/qn10-kernel-patches.git
PATCH_BRANCH=main
VCPUS=8
MEM=16384
RUNTIME_MIN=240
IMAGE=debian:trixie
EXECUTOR=/opt/fc-runner/executor
LIBEXEC=/usr/local/libexec/qn10-kernel-autobuild
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

WORK=${STATE_DIRECTORY:-/var/lib/qn10-kernel-autobuild}
OUT=$WORK/out
LOG=$WORK/build.log
host=$(hostname)
running=$(uname -r)

[ -n "$KERNEL_TAG" ] || { echo "KERNEL_TAG is not set in $CONF" >&2; exit 2; }

if [ "$REBUILD" = 1 ]; then
	latest=$KERNEL_TAG
	# 20261116.202611192045 sorts after 20261116 in dpkg.
	rev=${latest##*-}.$(date -u +%Y%m%d%H%M)
else
	# Tags end in their date: qcom-next-<version>-<YYYYMMDD>.
	latest=$(git ls-remote --tags --refs "$KERNEL_REPO" 'qcom-next-*' |
		sed -n 's#.*refs/tags/##p' | awk -F- '{print $NF, $0}' | sort -n | tail -1 | cut -d' ' -f2)
	[ -n "$latest" ] || { echo "cannot list the tags of $KERNEL_REPO" >&2; exit 1; }
	if [ "${latest##*-}" -le "${KERNEL_TAG##*-}" ]; then
		echo "running kernel is from $KERNEL_TAG, the newest tag is $latest: nothing to build"
		exit 0
	fi
	if [ "$(cat "$WORK/last-attempt" 2>/dev/null)" = "$latest" ]; then
		echo "$latest was already tried, see $LOG"
		exit 0
	fi
	rev=${latest##*-}
fi

rm -rf "$OUT"
mkdir -p "$OUT"
: >"$LOG"
echo "building $latest in a microVM, log: $LOG"
exec >>"$LOG" 2>&1
echo "== $(date -u '+%F %T') build $latest on $host (running $running)"

# The executor scripts read the job settings from CUSTOM_ENV_*, and run.sh
# exports them into the build script without the prefix. FC_RUNTIME has no
# prefix: only a host-side caller can set it, never a CI job.
export FC_RUNTIME=$RUNTIME_MIN
export CUSTOM_ENV_CI_JOB_ID="kernel-$rev"
export CUSTOM_ENV_FC_VCPUS=$VCPUS CUSTOM_ENV_FC_MEM=$MEM
export CUSTOM_ENV_CI_JOB_IMAGE=$IMAGE CUSTOM_ENV_CI_PROJECT_DIR=/root/builds
export CUSTOM_ENV_TAG=$latest CUSTOM_ENV_OLD_TAG=$KERNEL_TAG CUSTOM_ENV_REV=$rev CUSTOM_ENV_JOBS=$VCPUS
export CUSTOM_ENV_KERNEL_REPO=$KERNEL_REPO CUSTOM_ENV_PATCH_REPO=$PATCH_REPO
export CUSTOM_ENV_PATCH_BRANCH=$PATCH_BRANCH
# shellcheck source=/dev/null
. "$EXECUTOR/base.sh"
trap '"$EXECUTOR/cleanup.sh"' EXIT

"$EXECUTOR/prepare.sh" || { echo "== the microVM did not start"; exit 1; }
guest=$(cat "$STATE/guest_ip")
# shellcheck disable=SC2086 # SSH_OPTS from base.sh is a list of options
ssh $SSH_OPTS root@"$guest" 'cat >/root/builds/config' <"/boot/config-$running"
"$EXECUTOR/run.sh" "$LIBEXEC/build-in-vm.sh" build_script || true
# shellcheck disable=SC2086
status=$(ssh $SSH_OPTS root@"$guest" 'cat /root/builds/status' 2>/dev/null || echo "start")
# shellcheck disable=SC2086
ssh $SSH_OPTS root@"$guest" 'cat /root/builds/changes.txt' >"$WORK/changes.txt" 2>/dev/null ||
	echo "No change summary: the build stopped before it." >"$WORK/changes.txt"

# The change summary for a mail: the first 300 lines.
summary(){
	echo "== Changes (full list: $WORK/changes.txt)"
	echo
	head -n 300 "$WORK/changes.txt"
	[ "$(wc -l <"$WORK/changes.txt")" -le 300 ] || echo "  ... (cut at 300 lines)"
}

case $status in
start | setup | clone)
	# A network fault, most likely. No mail, and the next run tries again.
	echo "== stopped at $status, will retry on the next run"
	exit 1
	;;
ok) ;;
*)
	echo "$latest" >"$WORK/last-attempt"
	echo "== failed at $status"
	{
		echo "The automatic build of $latest failed at: $status."
		echo "Running kernel: $running, built from $KERNEL_TAG."
		echo
		echo "To try $latest again after a fix (for example, a new patch on"
		echo "$PATCH_BRANCH), run these commands on $host:"
		echo
		echo "  sudo rm $WORK/last-attempt"
		echo "  sudo systemctl start --no-block qn10-kernel-autobuild.service"
		echo
		echo "Full log: $LOG"
		echo "Last 40 lines:"
		echo
		tail -n 40 "$LOG"
		echo
		summary
	} | mail -s "[$host] kernel $latest: $status failed" "$MAILTO"
	exit 1
	;;
esac

echo "$latest" >"$WORK/last-attempt"
# shellcheck disable=SC2086
ssh $SSH_OPTS root@"$guest" 'tar -C /root/builds/out -cf - .' | tar -xf - -C "$OUT"
version=$(cat "$OUT/version")
echo "== done"

{
	echo "Kernel $version is built from $latest with the QN10 patches"
	echo "($(cat "$OUT/patches.txt")). All patches applied cleanly."
	echo
	echo "Packages in $OUT:"
	(cd "$OUT" && ls -1 ./*.deb)
	echo
	echo "To install it, make it the default boot entry, record its tag, and"
	echo "start it, run these commands on $host:"
	echo
	echo "  sudo sh $OUT/qn10-install-kernel.sh $OUT $latest"
	echo "  sudo sed -i 's/^KERNEL_TAG=.*/KERNEL_TAG=$latest/' $CONF"
	echo "  sudo reboot"
	echo
	echo "To go back, pick the previous entry in the boot menu."
	echo
	summary
} | mail -s "[$host] kernel $latest built, ready to install" "$MAILTO"
