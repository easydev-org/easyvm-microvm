# easyvm-microvm

Microvm guests, driven by [`easydev-org/easyvm`](https://github.com/easydev-org/easyvm).

## What a microvm is

The smallest machine that boots a modern Linux kernel. No firmware, no boot sector, no PCIe bus:
qemu is handed the kernel and an initramfs directly, and the disk arrives holding a root filesystem
that CI built. 512–768 MiB of RAM instead of 4 GiB, and seconds instead of forty minutes.

## What lives here

**Headless guests** - a root filesystem, a serial login, no display adapter:

| Directory | Distribution |
|---|---|
| `alpine-microvm/` | Alpine 3.21 |
| `debian-microvm/` | Debian 6.12 |
| `fedora-microvm/` | Fedora |
| `leap-microvm/` | openSUSE Leap |
| `nixos-microvm/` | NixOS |
| `ubuntu-microvm/` | Ubuntu |
| `netbsd-microvm/` | NetBSD 11.1, the first BSD here |

NETBSD IS NOT LINUX AND ITS TARBALL IS DIFFERENT: `netbsd-MICROVM` (a PUBLISHED kernel built with
NetBSD's MICROVM configuration, PVH + virtio-MMIO, so it boots with `-kernel` and no firmware) and
`netbsd.qcow2` (a root filesystem written by `mke2fs -d` from the release's `base` and `etc` sets).
There is no initramfs, because that kernel has `virtio_mmio`, `virtio_blk` and ext2fs built in.
`netbsd-GENERIC` does NOT work: it has no Linux boot-protocol header, so `-kernel` loops on SeaBIOS.

**Desktop variants** - a graphical session on a virtio-gpu device over PCIe, captured from the
scanout the noVNC console exports:

A DESKTOP MICROVM IS A DIFFERENT MACHINE FROM A HEADLESS ONE. `microvm_display: desktop` turns PCIe
ON and attaches `virtio-gpu-pci`, because `virtio-gpu-device` on the virtio-MMIO bus attaches and its
driver never binds - no `/dev/dri/card0`, so no compositor can start. The GPU's scanout IS what the
console shows, so `read:` photographs the desktop rather than a text prompt.

| Directory | Desktop |
|---|---|
| `arch-microvm/` | console only, no PCIe |
| `arch-sway-microvm/` | Sway (Wayland, wlr-screencopy) |
| `arch-xfce-microvm/` | XFCE on Xorg |
| `arch-xfce-wayland-microvm/` | XFCE on labwc |
| `arch-cinnamon-microvm/` | Cinnamon on Xorg |
| `arch-cinnamon-wayland-microvm/` | Cinnamon on muffin |
| `arch-lxqt-microvm/` | LXQt on Xorg |
| `arch-lxqt-wayland-microvm/` | LXQt on its Wayland session |
| `arch-i3-microvm/` | i3 on Xorg |
| `arch-mate-microvm/` | MATE |
| `arch-flashback-microvm/` | GNOME Flashback |
| `arch-deepin-microvm/` | Deepin (DDE) |
| `arch-enlightenment-microvm/` | Enlightenment |
| `arch-qtile-microvm/` | Qtile on Xorg |
| `arch-qtile-wayland-microvm/` | Qtile on its Wayland backend |
| `arch-labwc-microvm/` | labwc |
| `arch-wayfire-microvm/` | Wayfire |
| `arch-hyprland-microvm/` | Hyprland |
| `arch-mangowm-microvm/` | Mangowm |
| `arch-budgie-microvm/` | Budgie |
| `arch-phosh-microvm/` | Phosh (phone shell, 720x1280) |
| `arch-gnome-microvm/` | GNOME: GDM, then gnome-shell on Wayland |
| `arch-plasma-microvm/` | KDE Plasma on Wayland |
| `arch-plasma-mobile-microvm/` | Plasma Mobile |
| `arch-plasma-bigscreen-microvm/` | Plasma Bigscreen |

THE ONES WITH A MEASURED LIMIT ARE NOT HERE. `river`, `niri`, `weston`, `kylin` and `treeland` were
tried and dropped - their compositors expose no capture protocol this engine can read. `cinnamon` and
`enlightenment` are supported on X11 only, because their Wayland compositors (muffin, E's wl_drm)
export no screencopy. Each remaining note is in `.github/arch-rootfs.sh`.

## How a root filesystem is built

`.github/*-rootfs.sh` builds each one, and `.github/make-initramfs.py` assembles the initramfs. Those
are CI steps, not walkthrough steps: a microvm installs nothing, so the disk has to exist before the
guest is started.

## What lives elsewhere, on purpose

The **engine** - the daemon, the qemu argument builder, the walkthrough interpreter - is in
`easydev-org/easyvm`. The **CI machinery** is too: every workflow here calls
`easydev-org/easyvm/.github/workflows/stage.yml@main`.

Artifacts pull from and publish to this repository's own ghcr package, `easydev-org/easyvm-microvm`.
