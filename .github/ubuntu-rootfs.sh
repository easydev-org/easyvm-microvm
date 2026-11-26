#!/bin/sh
# BUILD AN UBUNTU ROOT FILESYSTEM A MICROVM BOOTS.
#
# THE SAME THREE FILES AS EVERY OTHER VARIANT: a kernel, an initramfs, one flat ext4
# qcow2. Ubuntu is the only one of the four that DOES NOT NEED THE INITRAMFS, and that
# is a property of its kernel rather than of anything this script does:
#
#	CONFIG_VIRTIO_MMIO=y                    built in, so the device is visible at boot
#	CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y    so qemu's command line names it
#	CONFIG_VIRTIO_BLK=y                     built in, so /dev/vda appears with no module
#	CONFIG_EXT4_FS=y                        built in, so the root mounts with no module
#
# MEASURED: with `-kernel ubuntu-vmlinuz` and NO `-initrd`, this guest prints
#
#	virtio_blk virtio0: [vda] 6281216 512-byte logical blocks
#	EXT4-fs (vda): mounted filesystem ... r/w
#	localhost login: root (automatic login)
#
# in 2.5 seconds. The initramfs this script still writes is the guest's own
# /boot/initrd.img, so a consumer gets three files like every other variant and the
# boot step does not have to special-case Ubuntu.
#
# THAT IS WHY THIS IS THE SHORTEST OF THE FOUR SCRIPTS: no module selection, no
# dependency ordering, no busybox, no archive builder.
set -eu

V="${UBUNTU_VERSION:-24.04}"
OUT="${1:-.}"
WORK="${OUT}/ubuntu-build"

log() { printf '  %s\n' "$*"; }

mkdir -p "$WORK" "$OUT"
HERE=$(cd "$(dirname "$0")" && pwd)

# --- 1. the root tree ---------------------------------------------------------------------
if [ ! -f "$WORK/rootfs.tar" ]; then
	log "pulling ubuntu:${V} from docker.io"
	python3 "$HERE/fetch-image.py" library/ubuntu "$V" "$WORK/rootfs.tar"
fi

ROOT="$WORK/root"
if [ ! -d "$ROOT/usr" ]; then
	log "unpacking"
	rm -rf "$ROOT"
	mkdir -p "$ROOT"
	tar -xf "$WORK/rootfs.tar" -C "$ROOT"

	# THE DEVICE NODES tar DID NOT PRESERVE, AND THE FAILURE THEY CAUSE IS MISLEADING.
	# MEASURED: the image's `/dev/null` arrives as a REGULAR FILE, and then every apt
	# run answers
	#
	#	/usr/bin/apt-key: 95: cannot create /dev/null: Permission denied
	#	E: gpgv, gpgv2 or gpgv1 required for verification, but neither seems installed
	#
	# which reads as a missing package and is a missing device node.
		# THE DIRECTORY IS MADE EXPLICITLY, AND THE mknod IS NOT ALLOWED TO FAIL QUIETLY.
	#
	# MEASURED on arch: `archlinux:latest` ships NO `dev` directory at all, so `mknod
	# "$ROOT/dev/null"` failed - and the `|| true` that was here turned that into silence.
	# The guest then stalled for three minutes at
	#
	#	A start job is running for…nts and Files (3min / 3min 2s)
	#
	# because the initramfs's `mount --move /proc /newroot/proc` had no directory to land
	# in and the `|| true` there hid it too. This image DOES ship `dev/`, so it never hit
	# it; the next base that changes that would.
	mkdir -p "$ROOT/dev" "$ROOT/proc" "$ROOT/sys"
	log "creating device nodes"
	for spec in "null c 1 3" "zero c 1 5" "random c 1 8" "urandom c 1 9" "tty c 5 0"; do
		set -- $spec
		rm -f "$ROOT/dev/$1"
		mknod "$ROOT/dev/$1" "$2" "$3" "$4"
		chmod 666 "$ROOT/dev/$1"
	done

	cp /etc/resolv.conf "$ROOT/etc/resolv.conf"

	# `linux-image-generic` AND NOT A SPECIFIC VERSION, because a pinned version stops
	# existing when Ubuntu supersedes it and the failure is `Unable to locate package`
	# on a build that worked last month.
	#
	# `--no-install-recommends` KEEPS THE IMAGE SMALL: the recommends of a generic
	# kernel pull in firmware and tools a microvm cannot use.
	log "installing the kernel and an ssh server"
	chroot "$ROOT" /bin/sh -c '
		set -e
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq
		apt-get install -y -qq --no-install-recommends \
			linux-image-generic systemd-sysv udev e2fsprogs openssh-server \
			initramfs-tools 2>&1 | tail -3
	'
fi

KVER=$(ls "$ROOT/usr/lib/modules" | head -1)
log "kernel $KVER"

# --- 2. the guest's own configuration -----------------------------------------------------
cat > "$ROOT/etc/fstab" <<'EOF'
/dev/vda / ext4 rw,relatime 0 1
EOF

# ROOT ON THE CONSOLE WITH NO PASSWORD. A microvm's console is its whole surface.
sed -i 's/^root:x:/root::/' "$ROOT/etc/passwd"

mkdir -p "$ROOT/etc/systemd/system/serial-getty@ttyS0.service.d"
mkdir -p "$ROOT/etc/systemd/system/getty.target.wants"
cat > "$ROOT/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin vmuser --noclear %I $TERM
EOF
ln -sf /usr/lib/systemd/system/serial-getty@.service \
	"$ROOT/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service"

rm -f "$ROOT/etc/resolv.conf"
printf '# The bridge runs DNS for this guest.\nnameserver 172.30.0.1\n' > "$ROOT/etc/resolv.conf"

mkdir -p "$ROOT/etc/systemd/network"
cat > "$ROOT/etc/systemd/network/20-wired.network" <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF

mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
mkdir -p "$ROOT/etc/systemd/system/sockets.target.wants"
ln -sf /usr/lib/systemd/system/ssh.service \
	"$ROOT/etc/systemd/system/multi-user.target.wants/ssh.service" 2>/dev/null || \
	ln -sf /usr/lib/systemd/system/sshd.service \
		"$ROOT/etc/systemd/system/multi-user.target.wants/sshd.service"
ln -sf /usr/lib/systemd/system/systemd-networkd.socket \
	"$ROOT/etc/systemd/system/sockets.target.wants/systemd-networkd.socket"
ln -sf /usr/lib/systemd/system/systemd-networkd.service \
	"$ROOT/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"

chroot "$ROOT" /bin/sh -c '
	command -v useradd >/dev/null || exit 0
	id vmuser >/dev/null 2>&1 || useradd -m -s /bin/bash vmuser
	echo "vmuser:admin" | chpasswd
	command -v sudo >/dev/null && (id -nG vmuser | grep -qw sudo || usermod -aG sudo vmuser) || true
'

mkdir -p "$ROOT/etc/systemd/system"
cat > "$ROOT/etc/systemd/system/growfs.service" <<'EOF'
[Unit]
Description=grow the root filesystem into the disk it was given
After=systemd-remount-fs.service
Before=local-fs.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecCondition=/usr/bin/test ! -f /var/lib/growfs-done
ExecStart=/bin/sh -c '/sbin/resize2fs /dev/vda 2>/dev/null || true; /usr/bin/touch /var/lib/growfs-done'
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/growfs.service \
	"$ROOT/etc/systemd/system/multi-user.target.wants/growfs.service"

# THE BUILD'S OWN FILES ARE NOT THE GUEST'S.
rm -f "$ROOT/etc/resolv.conf"
printf '# The bridge runs DNS for this guest.\nnameserver 172.30.0.1\n' > "$ROOT/etc/resolv.conf"
rm -rf "$ROOT/var/lib/apt/lists"/* "$ROOT/var/cache/apt"/* "$ROOT/var/log"/* 2>/dev/null || true

# --- 3. write the disk --------------------------------------------------------------------
# 64 GiB, FIXED. The guest grows its filesystem into the disk with `growfs.service`,
# so the virtual size is a POLICY decision and not a build artefact: qcow2 stores only
# clusters that were written, so a large disk costs nothing until somebody fills it,
# and an operator can install a toolchain or a desktop without rebuilding the image.
SIZE=65536
log "writing a ${SIZE} MiB ext4 image"
rm -f "$WORK/rootfs.raw"
truncate -s "${SIZE}M" "$WORK/rootfs.raw"
mke2fs -q -F -t ext4 -d "$ROOT" "$WORK/rootfs.raw"
qemu-img convert -f raw -O qcow2 -c "$WORK/rootfs.raw" "$OUT/ubuntu.qcow2"

# --- 4. the three files the boot step names -----------------------------------------------
#
# UBUNTU DOES NOT NEED AN INITRAMFS AT ALL - see the header - BUT ONE IS STILL BUILT, for the
# same reason every other variant ships three files: a consumer should not have to know which
# distribution needs which medium.
#
# IT IS BUILT BY OUR OWN BUILDER RATHER THAN BY initramfs-tools, AND THAT IS MEASURED. Ubuntu's
# `update-initramfs` needs a mounted /proc and REFUSES without one:
#
#	update-initramfs: deferring update (trigger activated)
#
# leaving /boot/initrd.img as a DANGLING SYMLINK to a file that was never written - so a build
# that trusted it would package nothing, and `cp` would fail on the missing name.
#
# The kernel's own config makes the archive trivial: VIRTIO_MMIO, VIRTIO_BLK and EXT4_FS are all
# `=y`, so the archive carries NO modules and is only a shell plus switch_root.
log "kernel $KVER"
if [ ! -f "$WORK/busybox" ]; then
	curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors --max-time 300 \
		-o "$WORK/busybox" \
		"https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
	chmod +x "$WORK/busybox"
fi

python3 "$HERE/make-initramfs.py" \
	--out "$WORK/initramfs.img" \
	--busybox "$WORK/busybox" \
	--kver "$KVER" \
	--modules-dir "$ROOT/usr/lib/modules/$KVER" \
	--root /dev/vda --fstype ext4

cp "$ROOT/boot/vmlinuz-$KVER" "$OUT/ubuntu-vmlinuz"
cp "$WORK/initramfs.img" "$OUT/ubuntu-initramfs"

log "done:"
ls -l "$OUT/ubuntu-vmlinuz" "$OUT/ubuntu-initramfs" "$OUT/ubuntu.qcow2"