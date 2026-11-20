#!/bin/sh
# BUILD THE ALPINE ROOT FILESYSTEM A MICROVM BOOTS.
#
# A microvm has NO FIRMWARE AND NO INSTALLER: qemu is handed a kernel, an initramfs and a disk. So the
# disk has to arrive ready, and this is what makes it. Nothing here installs Alpine - `apk` populates
# a directory and `mke2fs -d` writes it to an image, which is the same shape Firecracker's own
# getting-started guide uses.
#
# WHY NOT THE NETBOOT ARTIFACTS ALONE. Alpine publishes `vmlinuz-virt` and `initramfs-virt` for a
# DISKLESS guest: the initramfs mounts a squashfs `modloop`, keeps the root in tmpfs and asks the
# network for packages. MEASURED with those alone on a microvm:
#
#	Mounting boot media: ok.
#	Installing packages to root filesystem: OK: 0 MiB in 0 packages
#	/sbin/init not found in new root. Launching emergency recovery shell
#
# because there is no network in that machine and nothing was ever on disk.
#
# THE THREE OUTPUTS THIS PRODUCES, AND WHY EACH IS NEEDED:
#
#	alpine-vmlinuz     the kernel. Alpine ships it WITHOUT a version in the name - `vmlinuz-virt` -
#	                   which is why a path like `vmlinuz-6.12.x` fails with "No such file".
#	alpine-initramfs   REBUILT, because the stock one has 72 modules and ext4 is not among them. A
#	                   guest whose root is ext4 answers `mount: /dev/vda: No such device`. `mkinitfs`
#	                   with the ext4 feature is what fixes it.
#	alpine.qcow2       the root filesystem, as an ext4 image converted to qcow2. QCOW2 AND NOT RAW
#	                   because the engine boots every machine on an OVERLAY over the disk, and
#	                   `qemu-img create -b` refuses a raw backing file.
#
# AND `tty1` GETS A GETTY. That is what puts a LOGIN PROMPT ON THE VGA ADAPTER - the difference
# between an mp4 of a guest and an mp4 of a black field. Without it the guest is healthy and the video
# is empty, which is the failure this file exists to remove.
set -eu

V="${ALPINE_VERSION:-3.21}"
BASE="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}/v${V}"
OUT="${1:-.}"
WORK="${OUT}/alpine-build"

log() { printf '  %s\n' "$*"; }

# THE RUNNER IS ALREADY ROOT AND HAS NO `sudo`. MEASURED: the first CI run of this script died with
# `/__w/easyvm/easyvm/.github/alpine-rootfs.sh: 62: sudo: not found`. A developer machine may need it,
# so it is used only when it is there - and never for a command that is not chroot/NEWROOT.
if [ "$(id -u)" -eq 0 ]; then
	as_root() { "$@"; }
elif command -v sudo >/dev/null 2>&1; then
	as_root() { sudo "$@"; }
else
	log "not root and no sudo: apk/mkinitfs/mke2fs will fail"
	as_root() { "$@"; }
fi

mkdir -p "$WORK" "$OUT"

# --- 1. fetch -----------------------------------------------------------------------------
if [ ! -f "$WORK/minirootfs.tar.gz" ]; then
	log "fetching alpine-minirootfs-${V}"
	curl -fsSL --retry 3 --max-time 300 \
		-o "$WORK/minirootfs.tar.gz" \
		"${BASE}/releases/x86_64/alpine-minirootfs-${V}.0-x86_64.tar.gz"
fi

# --- 2. populate a root tree --------------------------------------------------------------
if [ ! -d "$WORK/root/usr" ]; then
	log "unpacking and installing the packages"
	rm -rf "$WORK/root"
	mkdir -p "$WORK/root"
	tar -xzf "$WORK/minirootfs.tar.gz" -C "$WORK/root"

	# THE MIRROR IS WRITTEN EXPLICITLY so a pinned `ALPINE_VERSION` cannot silently fall back to
	# whatever the minirootfs shipped configured.
	printf '%s/main\n%s/community\n' "$BASE" "$BASE" > "$WORK/root/etc/apk/repositories"
	as_root cp /etc/resolv.conf "$WORK/root/etc/resolv.conf"
	# AN APK THAT RUNS INSIDE chroot DOES NOT INHERIT THIS SHELL'S PROXY, and a runner behind one sees
	# `fetch ...: temporary failure in name resolution`. The variables are passed explicitly so a
	# direct-connect runner is unaffected.


	# linux-virt BRINGS THE KERNEL AND /lib/modules, which is what `mkinitfs` reads.
	#
	# NO X PACKAGES, AND REMOVING THEM IS THE FIX FOR A REAL MISREPORT. This list used to install
	# `openbox xorg-server xinit xterm xf86-video-vesa`, on the theory that they "make this a DESKTOP
	# rather than a serial console". MEASURED: they were installed into every alpine image and NEVER
	# EXECUTED - nothing in `/etc/inittab` started X - so the walkthrough that recorded this guest was
	# named `desktop.walk` and filmed a text login prompt. A package that nothing runs is 40 MiB of
	# image and a claim that is not true.
	#
	# A microvm cannot run X at all: no firmware (so no VESA framebuffer, no /dev/fb0) and no PCIe
	# (so `virtio-gpu` attaches and its driver never binds). `machine.Boot.Validate` refuses
	# `microvm_display: desktop` for that reason; see `vga-console.walk` for what this guest does
	# prove.
	#
	# THE PROXY IS PASSED INTO THE CHROOT, because `apk` reads it from the ENVIRONMENT and a
	# `/etc/profile.d` file is only sourced by a login shell. MEASURED: without this a runner behind a
	# proxy answers "temporary failure in name resolution" and installs 9 MiB of nothing.
	as_root env ${https_proxy:+https_proxy="$https_proxy"} ${http_proxy:+http_proxy="$http_proxy"} \
		chroot "$WORK/root" /sbin/apk add --no-cache \
		alpine-base linux-virt mkinitfs e2fsprogs openssh
	log "root tree: $(du -sm "$WORK/root" | cut -f1) MiB"
fi

ROOT="$WORK/root"
KVER=$(ls "$ROOT/lib/modules" | head -1)

# --- 3. rebuild the initramfs with ext4 ----------------------------------------------------
# WITHOUT THIS STEP THE GUEST CANNOT MOUNT ITS OWN ROOT. The stock netboot initramfs carries 72
# modules and `squashfs` is one of them while `ext4` is not - measured by listing the cpio members.
if [ ! -f "$WORK/initramfs-ext4" ]; then
	log "rebuilding the initramfs with ext4 (kernel $KVER)"
	grep -q 'ext4' "$ROOT/etc/mkinitfs/mkinitfs.conf" 2>/dev/null || {
		as_root sed -i 's/^features="\(.*\)"/features="\1 ext4 virtio_blk virtio_pci ata_piix sd_mod"/' \
			"$ROOT/etc/mkinitfs/mkinitfs.conf"
	}
	as_root chroot "$ROOT" /sbin/mkinitfs -o /boot/initramfs-ext4 "$KVER"
	as_root cp "$ROOT/boot/initramfs-ext4" "$WORK/initramfs-ext4"
fi

# --- 4. make the guest draw on the VGA adapter --------------------------------------------
# THE LOGIN PROMPT IS THE PICTURE. `tty1` is the adapter's console and `ttyS0` is the serial line; a
# getty on BOTH means the walkthrough can assert on the console (which is reliable) while the
# recording has something to show (which is the artifact).
log "writing inittab: a getty on tty1 and ttyS0"
as_root tee "$ROOT/etc/inittab" >/dev/null <<'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
# `-a vmuser` IS BUSYBOX GETTY'S AUTOLOGIN, the OpenRC equivalent of the systemd images'
# `agetty --autologin`. THE SESSION BELONGS TO vmuser BECAUSE THE DESKTOP DOES: PipeWire
# refuses root (`ConditionUser=!root`), so a root console cannot start a Wayland session.
# root keeps PID 1 and the services; the console is a user's.
tty1::respawn:/sbin/getty -L -a vmuser tty1 38400 vt100
ttyS0::respawn:/sbin/getty -L -a vmuser ttyS0 115200 vt100
EOF

# --- 4b. THE RESOLVER, WHICH WAS THE CONTAINER'S AND NOT THE GUEST'S -----------------------
#
# MEASURED: step 2 copies `/etc/resolv.conf` into the tree so `apk` can fetch packages inside the
# chroot, and NOTHING REPLACED IT. That file is the CONTAINER's:
#
#	nameserver 172.18.0.10
#
# 172.18.0.10 is the cluster's resolver, on a network the guest has no route to - its only route is
# `172.30.0.0/24` out of the bridge. So every name in the guest failed to resolve, permanently, on an
# image that had been built successfully.
#
# THE BRIDGE ANSWERS DNS ITSELF. easyvm runs dnsmasq on `172.30.0.1` with `port=53`, binding only
# `qemubr0`, forwarding to an upstream that works - so the address to name is the bridge, which is
# also what the DHCP lease already tells the guest (`dhcp-option=option:dns-server`).
#
# IT IS WRITTEN OUT RATHER THAN LEARNED, AND THAT IS SAFE BECAUSE THE ADDRESS IS A CONSTANT in
# easyvm (`net.BridgeIP = "172.30.0.1"`, beside `GuestIP`): one guest per container, fixed
# addressing, no allocation to coordinate. If that constant ever moves, this line and the DHCP option
# move with it - they are the same fact stated in two places, and a guest that finds one right and the
# other wrong is a failure mode worth naming.
as_root tee "$ROOT/etc/resolv.conf" >/dev/null <<'RESOLV'
# The bridge runs dnsmasq for this guest; it forwards to the cluster's resolver, which the guest
# cannot reach itself.
nameserver 172.30.0.1
RESOLV

# AND THE INTERFACE, BECAUSE A GUEST WITH NO CONFIGURATION GETS NO ADDRESS.
#
# MEASURED: `alpine-base` brings the `networking` service and `udhcpc`, but ships no
# `/etc/network/interfaces` and enables nothing - a container gets its interface from its runtime and
# the image has no reason to configure one. A VM is the opposite: its tap is a bare ethernet segment
# and SOMETHING INSIDE has to ask for a lease.
#
# The same failure was measured on the Debian guest and is written up in debian-rootfs.sh: the bridge
# ARP table showed `172.30.0.2 FAILED` while dnsmasq ran and the tap was up, because nothing ever
# sent a DHCPREQUEST. `eth0` is the name the kernel gives the virtio-net device.
as_root mkdir -p "$ROOT/etc/network"
as_root tee "$ROOT/etc/network/interfaces" >/dev/null <<'IFACE'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
IFACE

# `networking` IS IN THE `boot` RUNLEVEL, WHICH IS ONE OF THE `openrc` LINES ABOVE. Without the
# symlink the service is installed and never started, which looks identical to a network that cannot
# come up.
as_root mkdir -p "$ROOT/etc/runlevels/boot"
as_root ln -sf /etc/init.d/networking "$ROOT/etc/runlevels/boot/networking"

# --- 4b2. THE ACCOUNT AND THE DAEMON THE DRIVER EXPECTS --------------------------------------
#
# MEASURED: the daemon logs in as `vmuser` with password `admin` (`walk.File.SSHUser` defaults to
# `vmuser`, `--password` defaults to `admin`), and this image had no sshd at all - so `/api/state`
# would answer `ssh_ready: false` forever on a guest with a healthy network.
#
# NO ROOT LOGIN: the console autologins `vmuser` - see the inittab above for why the session
# belongs to a user - and remote root would be a second way in for no benefit. `PermitRootLogin no`
# states it.
as_root chroot "$ROOT" /bin/sh -c '
	set -e
	id vmuser >/dev/null 2>&1 || adduser -D -s /bin/ash vmuser
	echo "vmuser:admin" | chpasswd
	# alpine has no sudo by default; the driver only needs to LOG IN, and root is on the console.
	[ -d /etc/sudoers.d ] && echo "vmuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-vmuser && chmod 0440 /etc/sudoers.d/90-vmuser || true
	mkdir -p /etc/ssh/sshd_config.d
	cat > /etc/ssh/sshd_config.d/10-easyvm.conf <<SSHD
PasswordAuthentication yes
PermitRootLogin no
SSHD
'
# THE HOST KEYS ARE GENERATED AT BUILD TIME, NOT FIRST BOOT: `sshd` refuses to start without them, and
# a boot that has to wait for `ssh-keygen` on a microvm's entropy-less RNG is a boot that can hang.
as_root chroot "$ROOT" ssh-keygen -A 2>/dev/null || true
as_root ln -sf /etc/init.d/sshd "$ROOT/etc/runlevels/default/sshd"

# --- 4c. GROW INTO THE DISK, ONCE -----------------------------------------------------------
#
# The image is written with 8 GiB of headroom, which is a guess about what somebody will install. This
# grows the filesystem to whatever disk the guest was actually given, so that guess is never a
# ceiling.
#
# NO PARTITION TABLE: `mke2fs -d` wrote the filesystem directly onto the image, so this is
# `resize2fs` against the whole device - no `growpart`, no partition to move.
#
# OPENRC LOCAL, NOT A SYSTEMD UNIT, because this guest runs openrc. `local.d` scripts run late in
# boot with the filesystem already mounted; a stamp makes it once-only and a failure is ignored, since
# a guest that cannot grow should still boot.
as_root mkdir -p "$ROOT/etc/local.d"
as_root tee "$ROOT/etc/local.d/growfs.start" >/dev/null <<'GROW'
#!/bin/sh
# Grow / into the disk once. A disk that was never enlarged makes resize2fs fail, and that is fine.
[ -f /var/lib/growfs-done ] && exit 0
resize2fs /dev/vda 2>/dev/null || true
touch /var/lib/growfs-done
GROW
as_root chmod +x "$ROOT/etc/local.d/growfs.start"
as_root mkdir -p "$ROOT/etc/runlevels/default"
as_root ln -sf /etc/init.d/local "$ROOT/etc/runlevels/default/local"

# --- 5. write the disk --------------------------------------------------------------------
# `mke2fs -d` WRITES A DIRECTORY INTO AN IMAGE WITHOUT A LOOP DEVICE, which is what a container
# allows. This is the same step Firecracker's getting-started guide uses (`mkfs.ext4 -d`).
if [ ! -f "$WORK/rootfs.raw" ]; then
	# THE HEADROOM IS 8 GiB, AND IT COSTS ALMOST NOTHING BECAUSE QCOW2 IS SPARSE.
	#
	# MEASURED on the Debian image, which had the same `+ 250`: 1.32 GiB virtual, 502 MiB in the file,
	# because qcow2 stores only clusters that were written. `+ 120` here left an alpine guest with so
	# little free space that `apk add` reported
	#
	#	Space needed: 473 MB / 100 MB available
	#
	# - an image that cannot install packages, which is what a fixed small headroom means.
	# 64 GiB, FIXED. The guest grows its filesystem into the disk with `growfs.service`,
# so the virtual size is a POLICY decision and not a build artefact: qcow2 stores only
# clusters that were written, so a large disk costs nothing until somebody fills it,
# and an operator can install a toolchain or a desktop without rebuilding the image.
SIZE=65536
	log "writing a ${SIZE} MiB ext4 image"
	rm -f "$WORK/rootfs.raw"
	truncate -s "${SIZE}M" "$WORK/rootfs.raw"
	as_root mke2fs -q -F -t ext4 -d "$ROOT" "$WORK/rootfs.raw"
fi

log "converting to qcow2 (the engine boots every machine on an overlay, which needs qcow2)"
qemu-img convert -f raw -O qcow2 -c "$WORK/rootfs.raw" "$OUT/alpine.qcow2"

# --- 6. the two files the boot step names -------------------------------------------------
cp "$ROOT/boot/vmlinuz-virt" "$OUT/alpine-vmlinuz"
cp "$WORK/initramfs-ext4" "$OUT/alpine-initramfs"

log "done:"
ls -l "$OUT/alpine-vmlinuz" "$OUT/alpine-initramfs" "$OUT/alpine.qcow2"
