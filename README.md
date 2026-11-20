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

**Desktop variants** - a graphical session drawn into memory, captured over the wire:

| Directory | Desktop |
|---|---|
| `arch-microvm/` | console only |
| `arch-xfce-microvm/` | XFCE on Xvfb, captured over XSHM |
| `arch-cinnamon-microvm/` | Cinnamon |
| `arch-lxqt-microvm/` | LXQt |
| `arch-i3-microvm/` | i3 |
| `arch-sway-microvm/` | Sway (Wayland, wlr-screencopy) |

## How a root filesystem is built

`.github/*-rootfs.sh` builds each one, and `.github/make-initramfs.py` assembles the initramfs. Those
are CI steps, not walkthrough steps: a microvm installs nothing, so the disk has to exist before the
guest is started.

## What lives elsewhere, on purpose

The **engine** - the daemon, the qemu argument builder, the walkthrough interpreter - is in
`easydev-org/easyvm`. The **CI machinery** is too: every workflow here calls
`easydev-org/easyvm/.github/workflows/stage.yml@main`.

Artifacts pull from and publish to this repository's own ghcr package, `easydev-org/easyvm-microvm`.
