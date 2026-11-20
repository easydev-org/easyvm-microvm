#!/bin/sh
# BUILD AN OPENSUSE LEAP ROOT FILESYSTEM A MICROVM BOOTS.
#
# LEAP AND NOT TUMBLEWEED, AND THE KERNEL CONFIG IS NOT WHY. MEASURED from openSUSE's own
# kernel-source branches, every line of the product has the same microvm support:
#
#	SL-16.1 (Leap 16)          VIRTIO_MMIO=m  VIRTIO_MMIO_CMDLINE_DEVICES=y
#	SL-16.0 (Leap 16.0)        VIRTIO_MMIO=m  VIRTIO_MMIO_CMDLINE_DEVICES=y
#	SLE15-SP7 (Leap 15)        VIRTIO_MMIO=m  VIRTIO_MMIO_CMDLINE_DEVICES=y
#	master / stable (Tumbleweed) VIRTIO_MMIO=m  VIRTIO_MMIO_CMDLINE_DEVICES=y
#
# Leap is chosen because it has RELEASES: `opensuse/leap:16` points at a version that does
# not move underneath a build, while `opensuse/tumbleweed:latest` is a rolling tag whose
# contents change every snapshot. A rootfs published by tag is only reproducible if the
# tag means one thing.
#
# THE CONTAINER IMAGE IS NOT A BOOTABLE SYSTEM, AND THAT IS THE WORK THIS SCRIPT DOES.
# MEASURED: `opensuse/leap:16` unpacks to 115 MiB and has NO /sbin/init, NO systemd, and
# NO udev - it is a base for building containers, not machines. Three separate boot
# failures came out of that:
#
#	1. `switch_root: can't execute '/sbin/init': No such file or directory`
#	2. after installing systemd: `Kernel panic ... Attempted to kill init!`
#	   because libsystemd-shared was not in the tree
#	3. after udev was missing but systemd ran:
#	     A start job is running for /dev/ttyS0 (1min 30s / 1min 30s)
#	     Timed out waiting for device /dev/ttyS0.
#	   - the kernel had printed `ttyS0 at I/O 0x3f8 ... is a 16550A`, but with no udev
#	   nothing creates the node, so the getty waits for a device that has no /dev entry.
#
# SO THE PACKAGE MANAGER INSTALLS A SYSTEM RATHER THAN A SET OF FILES. zypper in a chroot
# works here after two fixes, both measured:
#
#	`zypper refresh` answers "libgpgme error ... Invalid crypto engine" when
#	/etc/resolv.conf is missing - the message names gpg and the cause is DNS.
#
#	`zypper install` answers "Could not resolve host: mirrors.tuna.tsinghua.edu.cn"
#	because the IMAGE's vendor configuration carries Chinese mirrors that do not
#	resolve from this network. `--from <repo>` would fix it on zypper 1.14; Leap 16's
#	zypper rejects that flag, so the mirror list itself is replaced.
set -eu

V="${OPENSUSE_VERSION:-16}"
OUT="${1:-.}"
WORK="${OUT}/leap-build"

log() { printf '  %s\n' "$*"; }

mkdir -p "$WORK" "$OUT"
HERE=$(cd "$(dirname "$0")" && pwd)

# --- 1. the root tree ---------------------------------------------------------------------
if [ ! -f "$WORK/rootfs.tar" ]; then
	log "pulling opensuse/leap:${V} from docker.io"
	python3 "$HERE/fetch-image.py" opensuse/leap "$V" "$WORK/rootfs.tar"
fi

ROOT="$WORK/root"
if [ ! -d "$ROOT/usr" ]; then
	log "unpacking"
	rm -rf "$ROOT"
	mkdir -p "$ROOT"
	tar -xf "$WORK/rootfs.tar" -C "$ROOT"

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

	# THE IMAGE'S VENDOR CONFIGURATION NAMES MIRRORS THAT DO NOT RESOLVE HERE. Each
	# .repo file is rewritten to the distribution's own CDN, which is what the baseurl
	# already says for the oss repository - the override is for the ones pointing at
	# regional mirrors.
	log "pointing zypper at the official CDN"
	for f in "$ROOT"/etc/zypp/repos.d/*.repo; do
		[ -f "$f" ] || continue
		sed -i -E 's#^(baseurl=)https?://[^/]+/#\1https://cdn.opensuse.org/#' "$f" 2>/dev/null || true
	done

	log "installing systemd, udev and an ssh server"
	chroot "$ROOT" /bin/sh -c '
		set -e
		# GNUPGHOME IS SET BECAUSE THE CHROOT HAS NO /root TO PUT A KEYRING IN, and
		# gpgme answers "Invalid crypto engine" when it cannot create one.
		export GNUPGHOME=/tmp/gnupg
		mkdir -p "$GNUPGHOME"
		chmod 700 "$GNUPGHOME"
		zypper --non-interactive --gpg-auto-import-keys refresh 2>&1 | tail -2
		# `kernel-default` IS THE PACKAGE THAT CARRIES vmlinuz AND /usr/lib/modules.
		# MEASURED without it: every other package installs, the tree has a working
		# systemd, and the build then stops at "no vmlinuz under ...".
		#
		# systemd, udev AND e2fsprogs TOGETHER: the first two are what makes the tree a
		# system, the third is what growfs needs at first boot.
		zypper --non-interactive install \
			kernel-default systemd udev e2fsprogs openssh-server 2>&1 | tail -3
	'
fi

KVER=$(ls "$ROOT/usr/lib/modules" | head -1)
log "kernel $KVER"

# --- 2. the initramfs ---------------------------------------------------------------------
KERNEL="$ROOT/usr/lib/modules/$KVER/vmlinuz"
[ -f "$KERNEL" ] || { log "no vmlinuz under $ROOT/usr/lib/modules/$KVER"; exit 1; }

# SUSE'S KERNEL IS THE ONE OF THE FOUR THAT NEEDS THE MOST MODULES, ALL BECAUSE ITS
# virtio_blk AND ext4 ARE BUILT AS MODULES RATHER THAN INTO THE KERNEL. MEASURED from the
# package's own config:
#
#	CONFIG_VIRTIO_BLK=m   CONFIG_EXT4_FS=m
#
# ext4 depends on jbd2 and mbcache, and jbd2 depends on crc16 - none of which any kernel
# in this family has built in. The order below is a DEPENDENCY ORDER and not a list: insmod
# refuses a module whose symbols are not already present, and the initramfs loads them in
# exactly this sequence.
log "building the initramfs"
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
	--root /dev/vda --fstype ext4 \
	--module crc16 --module mbcache --module jbd2 --module ext4 \
	--module virtio_mmio --module virtio_blk

# --- 3. the guest's own configuration -----------------------------------------------------
cat > "$ROOT/etc/fstab" <<'EOF'
/dev/vda / ext4 rw,relatime 0 1
EOF

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
	command -v sudo >/dev/null && (id -nG vmuser | grep -qw wheel || usermod -aG wheel vmuser) || true
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
ExecStart=/bin/sh -c '/usr/sbin/resize2fs /dev/vda 2>/dev/null || true; /usr/bin/touch /var/lib/growfs-done'
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/growfs.service \
	"$ROOT/etc/systemd/system/multi-user.target.wants/growfs.service"

rm -f "$ROOT/etc/resolv.conf"
printf '# The bridge runs DNS for this guest.\nnameserver 172.30.0.1\n' > "$ROOT/etc/resolv.conf"
rm -rf "$ROOT/var/cache/zypp"/* "$ROOT/var/log"/* "$ROOT/tmp/gnupg" 2>/dev/null || true

# --- 4. write the disk --------------------------------------------------------------------
# 64 GiB, FIXED. The guest grows its filesystem into the disk with `growfs.service`,
# so the virtual size is a POLICY decision and not a build artefact: qcow2 stores only
# clusters that were written, so a large disk costs nothing until somebody fills it,
# and an operator can install a toolchain or a desktop without rebuilding the image.
SIZE=65536
log "writing a ${SIZE} MiB ext4 image"
rm -f "$WORK/rootfs.raw"
truncate -s "${SIZE}M" "$WORK/rootfs.raw"
mke2fs -q -F -t ext4 -d "$ROOT" "$WORK/rootfs.raw"
qemu-img convert -f raw -O qcow2 -c "$WORK/rootfs.raw" "$OUT/leap.qcow2"

# --- 5. the three files the boot step names -----------------------------------------------
log "kernel $KVER"
cp "$KERNEL" "$OUT/leap-vmlinuz"
cp "$WORK/initramfs.img" "$OUT/leap-initramfs"

log "done:"
ls -l "$OUT/leap-vmlinuz" "$OUT/leap-initramfs" "$OUT/leap.qcow2"