#!/bin/sh
# BUILD A FEDORA ROOT FILESYSTEM A MICROVM BOOTS.
#
# THE SAME SHAPE AS alpine-rootfs.sh AND debian-rootfs.sh: a kernel, an initramfs, and
# ONE FLAT ext4 qcow2 with no partition table. What differs is where the parts come
# from, and each difference was measured.
#
# THE ROOT TREE IS THE OFFICIAL CONTAINER IMAGE. Fedora publishes no bootstrap tarball
# and no cloud image small enough to unpack cheaply; `docker pull fedora` is a root
# filesystem and `fetch-image.py` is the four HTTP requests that pull makes.
#
# THE KERNEL COMES FROM dnf, IN A CHROOT, and it is WHY THIS SCRIPT RUNS AS ROOT.
# `kernel-core` is the package that carries vmlinuz and /usr/lib/modules; the plain
# `kernel` package is the same kernel plus a bootloader nothing here can use.
#
# THE INITRAMFS IS BUILT BY .github/make-initramfs.py, NOT BY dracut.
#
# MEASURED: dracut refuses to run without /proc and /dev/fd -
#
#	dracut[E]: No '/dev/log' or 'logger' included for syslog logging
#	/usr/lib/dracut/dracut-functions.sh: line 1511: /dev/fd/63: No such file or directory
#	findmnt: can't read /proc/mounts: No such file or directory
#
# - and neither this project's build pod nor an unprivileged build container can mount
# proc. What a microvm needs from an initramfs is small: a shell, the modules that make
# /dev/vda appear, and a switch_root. That is built directly, and it removes dracut from
# the dependency list entirely.
#
# WHAT THIS KERNEL NEEDS IN THE INITRAMFS, read from its own config:
#
#	CONFIG_VIRTIO_MMIO=m              a module, so it must be loaded
#	CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y   so qemu's command line names the device
#	CONFIG_VIRTIO_BLK=y               built in - no module needed
#	CONFIG_EXT4_FS=y                  built in - no module needed
#
# so exactly ONE module goes in the archive.
set -eu

V="${FEDORA_VERSION:-latest}"
OUT="${1:-.}"
WORK="${OUT}/fedora-build"

log() { printf '  %s\n' "$*"; }

mkdir -p "$WORK" "$OUT"

HERE=$(cd "$(dirname "$0")" && pwd)

# --- 1. the root tree ---------------------------------------------------------------------
if [ ! -f "$WORK/rootfs.tar" ]; then
	log "pulling fedora:${V} from docker.io"
	python3 "$HERE/fetch-image.py" library/fedora "$V" "$WORK/rootfs.tar"
fi

ROOT="$WORK/root"
if [ ! -d "$ROOT/usr" ]; then
	log "unpacking"
	rm -rf "$ROOT"
	mkdir -p "$ROOT"
	tar -xf "$WORK/rootfs.tar" -C "$ROOT"

	# THE DEVICE NODES THE CONTAINER IMAGE DOES NOT CARRY. MEASURED: tar stores the
	# `/dev/null` of the image as a REGULAR FILE, so `apt-get`/`dnf` scripts that write
	# to it fail with `Permission denied` inside the chroot - a dnf that cannot write
	# /dev/null cannot install anything. mknod needs CAP_MKNOD, which the build has.
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
	for spec in "null c 1 3" "zero c 1 5" "random c 1 8" "urandom c 1 9"; do
		set -- $spec
		rm -f "$ROOT/dev/$1"
		mknod "$ROOT/dev/$1" "$2" "$3" "$4"
		chmod 666 "$ROOT/dev/$1"
	done

	cp /etc/resolv.conf "$ROOT/etc/resolv.conf"

	# THE MIRROR IS THE IMAGE'S OWN. Fedora's container image points at the official
	# metalink, which resolves from anywhere; overriding it would make the image depend
	# on this build host's route.
	log "installing the kernel and an ssh server"
	chroot "$ROOT" /bin/sh -c '
		set -e
		dnf install -y --setopt=install_weak_deps=False \
			kernel-core openssh-server e2fsprogs 2>&1 | tail -3
		# THE CHROOT HAS NO /proc, AND DNF SCRIPTLETS SAY SO. They are non-fatal -
		# MEASURED, the install completes and prints "Complete!" - but the warning is
		# kept visible rather than silenced, because it is the reason the presets are
		# applied by hand below instead of expecting systemd to have run them.
	'
fi

KVER=$(ls "$ROOT/usr/lib/modules" | head -1)
log "kernel $KVER"

# --- 2. the initramfs ---------------------------------------------------------------------
KERNEL="$ROOT/usr/lib/modules/$KVER/vmlinuz"
[ -f "$KERNEL" ] || { log "no vmlinuz under $ROOT/usr/lib/modules/$KVER"; exit 1; }

if [ ! -f "$WORK/busybox" ]; then
	log "fetching a static busybox"
	curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors --max-time 300 \
		-o "$WORK/busybox" \
		"https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
	chmod +x "$WORK/busybox"
fi

log "building the initramfs"
python3 "$HERE/make-initramfs.py" \
	--out "$WORK/initramfs.img" \
	--busybox "$WORK/busybox" \
	--kver "$KVER" \
	--modules-dir "$ROOT/usr/lib/modules/$KVER" \
	--root /dev/vda --fstype ext4 \
	--module virtio_mmio

# --- 3. the guest's own configuration -----------------------------------------------------
#
# EVERY ONE OF THESE WAS A BOOT FAILURE OR A BLANK SCREEN BEFORE IT WAS WRITTEN.
#
# THE FSTAB NAMES /dev/vda BECAUSE THERE IS NO BOOTLOADER TO PASS root=. It also marks
# the filesystem ` 1`, so a guest that was never cleanly shut down repairs itself
# rather than refusing to mount.
cat > "$ROOT/etc/fstab" <<'EOF'
/dev/vda / ext4 rw,relatime 0 1
EOF

# ROOT LOGS IN ON THE SERIAL CONSOLE WITH NO PASSWORD. A microvm's console is its whole
# surface, and a login nobody can answer is a dead guest. `root::` is an EMPTY password,
# which login accepts without PAM asking.
sed -i 's/^root:x:/root::/' "$ROOT/etc/passwd"

# THE SERIAL GETTY, ON ttyS0, WITH AUTOLOGIN. `console=ttyS0` on the kernel line is what
# sends kernel output there; this is what puts a PROMPT there.
mkdir -p "$ROOT/etc/systemd/system/serial-getty@ttyS0.service.d"
mkdir -p "$ROOT/etc/systemd/system/getty.target.wants"
cat > "$ROOT/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin vmuser --noclear %I $TERM
EOF
ln -sf /usr/lib/systemd/system/serial-getty@.service \
	"$ROOT/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service"

# A RESOLVER THAT DOES NOT DEPEND ON ANYTHING STARTING FIRST. The bridge address is
# where this guest's DNS lives; see the Debian script for the measurement that made
# this a static file rather than systemd-resolved.
rm -f "$ROOT/etc/resolv.conf"
printf '# The bridge runs DNS for this guest.\nnameserver 172.30.0.1\n' > "$ROOT/etc/resolv.conf"

# THE NETWORK, ASKED FOR RATHER THAN ASSUMED. A microvm gets a bare tap with no DHCP
# client of its own; without this the guest has no address and every `ssh` waits.
mkdir -p "$ROOT/etc/systemd/network"
cat > "$ROOT/etc/systemd/network/20-wired.network" <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF

# FEDORA'S IMAGE DOES NOT ENABLE sshd, and its presets cannot be applied without /proc.
# MEASURED: a guest with sshd installed and not enabled answers `Connection refused` on
# port 22 forever, which reads as a broken network.
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/sshd.service \
	"$ROOT/etc/systemd/system/multi-user.target.wants/sshd.service"

# AND THE SAME FOR THE NETWORK. `systemd-networkd` is socket-activated on Fedora, so the
# socket is what has to be enabled; enabling only the service starts nothing.
mkdir -p "$ROOT/etc/systemd/system/sockets.target.wants"
ln -sf /usr/lib/systemd/system/systemd-networkd.socket \
	"$ROOT/etc/systemd/system/sockets.target.wants/systemd-networkd.socket"
ln -sf /usr/lib/systemd/system/systemd-networkd.service \
	"$ROOT/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"

# THE ACCOUNT THE DRIVER LOGS IN AS, with the password the driver defaults to. Without
# it `/api/state` answers ssh_ready: false on a guest whose network is fine.
chroot "$ROOT" /bin/sh -c '
	command -v useradd >/dev/null || exit 0
	id vmuser >/dev/null 2>&1 || useradd -m -s /bin/bash vmuser
	echo "vmuser:admin" | chpasswd
	command -v sudo >/dev/null && (id -nG vmuser | grep -qw wheel || usermod -aG wheel vmuser) || true
'

# GROW INTO THE DISK ONCE, because the 8 GiB of headroom below is a guess about what
# somebody will install. Same reasoning as the other two images.
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

# THE BUILD'S OWN FILES ARE NOT THE GUEST'S. The chroot's resolver pointed at this
# host's DNS and its dnf cache is hundreds of megabytes of packages the guest will
# never read.
rm -f "$ROOT/etc/resolv.conf"
printf '# The bridge runs DNS for this guest.\nnameserver 172.30.0.1\n' > "$ROOT/etc/resolv.conf"
rm -rf "$ROOT/var/cache/dnf" "$ROOT/var/cache/libdnf5" "$ROOT/var/log"/* 2>/dev/null || true

# --- 4. write the disk --------------------------------------------------------------------
#
# THE HEADROOM IS 8 GiB AND IT COSTS ALMOST NOTHING: qcow2 stores only clusters that were
# written. MEASURED on the Debian image: 1.32 GiB virtual, 502 MiB in the file.
# 64 GiB, FIXED. The guest grows its filesystem into the disk with `growfs.service`,
# so the virtual size is a POLICY decision and not a build artefact: qcow2 stores only
# clusters that were written, so a large disk costs nothing until somebody fills it,
# and an operator can install a toolchain or a desktop without rebuilding the image.
SIZE=65536
log "writing a ${SIZE} MiB ext4 image"
rm -f "$WORK/rootfs.raw"
truncate -s "${SIZE}M" "$WORK/rootfs.raw"
mke2fs -q -F -t ext4 -d "$ROOT" "$WORK/rootfs.raw"
qemu-img convert -f raw -O qcow2 -c "$WORK/rootfs.raw" "$OUT/fedora.qcow2"

# --- 5. the two files the boot step names -------------------------------------------------
log "kernel $KVER"
cp "$KERNEL" "$OUT/fedora-vmlinuz"
cp "$WORK/initramfs.img" "$OUT/fedora-initramfs"

log "done:"
ls -l "$OUT/fedora-vmlinuz" "$OUT/fedora-initramfs" "$OUT/fedora.qcow2"