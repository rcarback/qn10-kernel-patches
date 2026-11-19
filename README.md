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

Each patch is a local test patch. None of them has gone upstream.
The device tree series has its own repository.

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

## Install

Copy the `linux-image` package to the QN10, then run
`sudo dpkg -i linux-image-7.4.0-rc1-qn10+_*.deb`.
For the first install of a kernel version, use `qn10-install-kernel.sh`. It
also places the device tree and sets the boot entry title.
