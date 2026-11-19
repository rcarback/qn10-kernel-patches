# QN10 kernel patches

Local patches and build scripts for the qcom-next kernel that runs on the
ASUS Ascent QN10 (Snapdragon X2, Glymur). The patches apply to the
qualcomm-linux/kernel tag `qcom-next-7.4-rc1-20261116`.

## Patches

| Patch | State |
|-------|-------|
| `0001-firmware-qcom-scm-Allow-QSEECOM-on-ASUS-Ascent-QN10.patch` | Built |
| `0002-nvme-speed_switch-Limit-target-rate-to-both-link-ends.patch` | Built |
| `0003-rtc-qcom-glink-Succeed-when-SET_REAL_TIME-succeeds.patch` | Built |
| `0004-soundwire-bus-Handle-SDCA-interrupts-for-class-0-devices.patch` | Built |
| `0005-usb-dwc3-Allow-keeping-USB2.0-retries.patch` | Built, not used (no effect on the KVM) |
| `0006-soundwire-qcom-Copy-DPn-banks-when-the-master-does-not-switch.patch` | Built |
| `0007-ASoC-codecs-wcd9378-sdca-Do-not-halve-the-TX-host-clock.patch` | Built |
| `0008-firmware-qcom-scm-Retry-PAS-init-from-TZMem.patch` | Built |
| `0009-drm-msm-adreno-Skip-the-zap-shader-when-the-kernel-runs-at-EL2.patch` | Built (the GPU runs without the zap shader) |
| `0010-rtc-qcom-glink-Fail-a-set-property-the-firmware-refuses.patch` | Built |
| `0011-usb-core-Add-ctrl_retries-for-control-transfer-errors.patch` | Built, used with `usbcore.ctrl_retries=3` |
| `0012-usb-hub-Check-the-port-after-a-reset-request-with-a-transaction-error.patch` | Built (KVM keyboard and mouse work) |
| `0013-dt-bindings-arm-qcom-Add-ASUS-Ascent-QN10.patch` | Built |
| `0014-arm64-dts-qcom-Add-ASUS-Ascent-QN10.patch` | Built (the DTB matches the one the QN10 boots) |

Each patch is a local test patch. None of them has gone upstream.
Patches 0013 and 0014 add the QN10 device tree, so each build compiles
`glymur-asus-ascent-qn10.dtb` and the kernel package ships it.

## Workarounds for the keyboard and mouse

The `usb/` folder holds two workarounds that run on the QN10. Patches 0011
and 0012 handle the errors that remain.

| File | Installs to | Purpose |
|------|-------------|---------|
| `qn10-usb3-fallback.sh` | `/usr/local/sbin/qn10-usb3-fallback` | Moves a USB-A port to USB 2 when its USB 3 link stays in Polling, and turns USB 3 back on when the port has been empty for 20 seconds |
| `qn10-usb3-fallback.service` | `/etc/systemd/system/` | Runs the fallback script at boot |
| `70-qn10-kvm-reconfigure.rules` | `/etc/udev/rules.d/` | Configures the KVM hub (Genesys 05e3:0610 rev 06.56) again when it arrives, so the keyboard behind it works after a switch from Windows |

Connect the KVM to a USB-C port. Through the internal USB-A hub, about 13%
of control transfers to the KVM fail. A test of 300 transfers through a USB-C
port had 0 failures.

## Build

Build in the `qn10-build` OrbStack VM. `REV` sets the Debian package
revision.

```sh
orb -m qn10-build -u root env REV=15 TERM=dumb PAGER=cat sh build-kernel.sh
```

The script clones the tag and applies `*.patch` only when the source tree
does not exist yet. To add a patch to an existing tree, apply it to that
tree with `git apply`, then run the script again.

`qn10-native-setup.sh` and `qn10-native-build.sh` build on the QN10 itself.

## Kernel config

Each build starts from the config of the running kernel, then merges
`qn10.config` and runs `make olddefconfig`. The build fails if an option from
`qn10.config` is not in the final config. `olddefconfig` drops an option when
its dependencies are missing, and this check catches that.

`qn10.config` turns on these options:

| Option | Reason |
|---|---|
| `CONFIG_DM_CRYPT=m` | Swap encrypted with a random key at each boot |
| `CONFIG_SECURITY_YAMA=y` | Restricts `ptrace` |
| `CONFIG_SECURITY_LANDLOCK=y` | Lets programs sandbox themselves |
| `CONFIG_LSM="landlock,lockdown,yama,apparmor,bpf"` | The packaged config builds AppArmor but leaves it out of this list, so AppArmor does not run |

## Automatic builds

The `auto/` folder builds each new qcom-next tag on the QN10, in a Firecracker
microVM of the CI runner. A timer runs `qn10-kernel-autobuild.sh` every night.
If a tag is newer than `KERNEL_TAG` in `/etc/default/qn10-kernel-autobuild`,
the script does these steps:

1. Starts a microVM with 8 vCPUs, 16 GiB, and a limit of 4 hours, through the
   runner's executor scripts.
2. Runs `build-in-vm.sh` in a `debian:trixie` container. That script applies
   each patch of this repository to the tag with `git apply`. Then it builds
   the packages with the config of the running kernel.
3. Copies the packages, the DTB from that build, and `qn10-install-kernel.sh`
   out to `/var/lib/qn10-kernel-autobuild/out`.
4. Mails a ready-to-install report, or the stage that failed with the last 40
   lines of the log.

The job tries each tag once. A stop during setup or clone counts as a network
fault, so the next run tries again without a mail. The job never installs a
kernel.

| File | Installs to |
|------|-------------|
| `auto/qn10-kernel-autobuild.sh` | `/usr/local/sbin/qn10-kernel-autobuild` |
| `auto/build-in-vm.sh` | `/usr/local/libexec/qn10-kernel-autobuild/build-in-vm.sh` |
| `auto/qn10-kernel-autobuild.service` and `.timer` | `/etc/systemd/system/` |

The service runs as `gitlab-runner`, the user that can start microVMs through
`fc-helper`. The 4-hour limit is the fourth argument of `fc-helper vm-start`.
CI jobs cannot set it and keep the default of 1 hour. A build of
`qcom-next-7.4-rc1-20261116` took 8 minutes.

## Install

Copy the `linux-image` package to the QN10. Then run
`sudo sh qn10-install-kernel.sh DIR TAG`, where `DIR` holds the package and
`glymur-asus-ascent-qn10.dtb`. The script reads the kernel version from the
package and places the device tree. Then it installs the package and makes
the new boot entry the default. After you install a kernel, set `KERNEL_TAG` in
`/etc/default/qn10-kernel-autobuild` to its tag.
