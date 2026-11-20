#!/bin/sh
# BUILD THE DEBIAN ROOT FILESYSTEM A MICROVM BOOTS, OUT OF THE PUBLISHED IMAGE.
#
# `debootstrap` IS NOT AVAILABLE HERE and that is not a workaround, it is a reason: MEASURED,
# `apt-get update` inside the 2 GiB lab pod is OOM-killed before the package could be installed.
# Debian publishes the same content as a container image, whose layers ARE a root filesystem - which
# is the identical "populate a directory, then mke2fs -d" shape `alpine-rootfs.sh` uses.
#
# NO INSTALLER RUNS. A microvm is handed a kernel, an initramfs and a disk; there is no firmware to
# read a boot sector, so the disk has to arrive holding a system.
#
# THE FOUR THINGS THAT ARE NOT THE SAME AS UNTARRING IT:
#
#   1. /etc/fstab MUST NOT NAME A PARTITION THAT DOES NOT EXIST. The image this replaces carried
#
#        PARTUUID=0f6986d9-... /boot/efi vfat defaults,umask=077 0 2
#
#      and a microvm has no ESP: qemu hands the kernel over directly. systemd could not satisfy the
#      mount, local-fs.target failed, and the guest dropped to
#
#        You are in emergency mode...
#        Cannot open access to console, the root account is locked.
#
#      MEASURED on /disks/lab/d13/console.log - 710 lines, and `login:` appears ZERO times.
#
#   2. THE INITRAMFS MUST ACTUALLY CONTAIN A WORKING MODULE TREE. The image this replaces had
#      `virtio_blk.ko.xz` and `virtio_mmio.ko.xz` present but NO `modules.dep` and NO `/init` at all
#      - a hand-assembled half-file. MEASURED, it boots to
#
#        ALERT! /dev/vda does not exist. Dropping to a shell!
#
#      even though qemu DID inject `virtio_mmio.device=512@0xfeb00e00:12` on the command line, which
#      is visible in the same log. A module that cannot be resolved is a module that never loads.
#
#   3. THE KERNEL AND ITS MODULES MUST BE THE SAME BUILD. The modules come from the `linux-image`
#      package installed INTO the tree, never from the host, or `insmod` answers "version magic".
#
#   4. ROOT MUST BE ABLE TO LOG IN. `root::` in /etc/shadow is an empty password, which login accepts
#      only if PAM is told to; the autologin drop-in below is what makes the console reach a prompt
#      without asking.
set -eu

V="${DEBIAN_VERSION:-trixie}"
# DESKTOP=1 BUILDS THE XFCE GUEST; DESKTOP=0 BUILDS THE SAME SYSTEM WITHOUT A SCREEN.
#
# THE TWO ARE ONE SCRIPT RATHER THAN TWO, because everything that makes a microvm BOOT is identical:
# the kernel, the virtio modules, the initramfs, the fatal fstab, the autologin, the DHCP interface and
# the 8 GiB of headroom. A second script would be a copy of all of that with the package list changed,
# and the copies would drift - which is the failure this repository has already paid for once with the
# three rootfs scripts.
#
# WHAT THE SWITCH TURNS OFF: Xvfb, the XFCE session, easystream, PulseAudio and its null sink,
# xclip/at-spi2-core, and the units that start them. What it leaves: an ssh-reachable Debian with
# systemd, a DHCP address and nothing drawing anything.
DESKTOP="${DESKTOP:-1}"

# THE PACKAGES THE SCREEN NEEDS, EMPTY WHEN THERE IS NO SCREEN. Kept as one string so the apt line
# above stays a single command in both variants - a second `apt-get install` would be a second
# transaction, and a failure in it would leave a tree with some of the desktop installed.
if [ "$DESKTOP" = "1" ]; then
	DESKTOP_PKGS="xvfb xfce4 xfce4-terminal dbus-x11 xauth x11-utils x11-apps \
		libx264-164 libyuv0 libxcb-xtest0 libpipewire-0.3-0t64 \
		xclip at-spi2-core pulseaudio pulseaudio-utils dbus"
else
	DESKTOP_PKGS=""
fi
OUT="${1:-.}"
WORK="${OUT}/debian-build"
# SEE THE `DEBIAN_MIRROR` BLOCK BELOW THE SOURCES FOR THE MEASUREMENT. `DEBIAN_MIRROR=` (empty)
# keeps the image's own `deb.debian.org`, which is the right default for anyone not behind this
# lab's proxy; the default here is the mirror that measured 26 MB/s from it.
MIRROR="${DEBIAN_MIRROR-http://mirrors.ustc.edu.cn}"

log() { printf '  %s\n' "$*"; }
mkdir -p "$WORK" "$OUT"

# --- 1. fetch the image's layers -------------------------------------------------------------
# THE REGISTRY RATHER THAN A GITHUB MIRROR: MEASURED, the debuerreotype branch serves the rootfs
# only inside an OCI blob (`trixie/oci/blobs/...`), while the registry hands back the compressed
# layer directly and is the same artifact `docker pull debian:trixie` would give.
if [ ! -f "$WORK/rootfs.tar" ]; then
	log "resolving debian:${V} on docker.io"
	token=$(curl -fsSL --max-time 60 --retry 5 --retry-delay 3 --retry-all-errors \
		"https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/debian:pull" \
		| python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')

	digest=$(curl -fsSL --max-time 60 --retry 5 --retry-delay 3 --retry-all-errors \
		-H "Authorization: Bearer $token" \
		-H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' \
		"https://registry-1.docker.io/v2/library/debian/manifests/${V}" \
		| python3 -c '
import json,sys
for m in json.load(sys.stdin).get("manifests", []):
    p = m.get("platform", {})
    if p.get("architecture") == "amd64" and p.get("os") == "linux":
        print(m["digest"]); break
')
	[ -n "$digest" ] || { log "no amd64 manifest for $V"; exit 1; }
	log "amd64 manifest $digest"

	# THE LAYER LIST, IN ORDER. Debian is a single layer, but the loop is written for the general
	# case: applying only the first layer of a multi-layer image produces a tree with no / etc.
	layers=$(curl -fsSL --max-time 60 --retry 5 --retry-delay 3 --retry-all-errors \
		-H "Authorization: Bearer $token" \
		-H 'Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
		"https://registry-1.docker.io/v2/library/debian/manifests/${digest}" \
		| python3 -c '
import json,sys
for l in json.load(sys.stdin)["layers"]:
    print(l["digest"])
')
	rm -f "$WORK"/layer-*
	i=0
	for d in $layers; do
		i=$((i+1))
		log "layer $i: $d"
		# RETRIED, BECAUSE A TLS RESET MID-BLOB IS TRANSIENT AND FATAL TO A ONE-SHOT CURL.
		#
		# MEASURED: `curl: (35) TLS connect error: error:0A000126:SSL routines::unexpected eof while
		# reading` on a 47 MiB layer, while three retries of the same request immediately afterwards
		# each returned 200. The path to `registry-1.docker.io` resets long-lived TLS sessions
		# intermittently, and a build script that treats the first reset as a failure can never finish.
		#
		# `--retry-all-errors` IS THE PART THAT MATTERS: plain `--retry` covers timeouts and 5xx but
		# NOT a TLS error, which is exactly what this path produces.
		curl -fsSL --max-time 900 --retry 5 --retry-delay 3 --retry-all-errors \
			-H "Authorization: Bearer $token" \
			"https://registry-1.docker.io/v2/library/debian/blobs/${d}" -o "$WORK/layer-$i"
	done
	: > "$WORK/rootfs.tar"
	for f in "$WORK"/layer-*; do cat "$f" >> "$WORK/rootfs.tar"; done
fi
log "rootfs tar: $(( $(stat -c %s "$WORK/rootfs.tar") >> 20 )) MiB"

ROOT="$WORK/root"
if [ ! -d "$ROOT/etc" ]; then
	log "unpacking"
	rm -rf "$ROOT"; mkdir -p "$ROOT"
	python3 - "$WORK/rootfs.tar" "$ROOT" <<'PY'
import sys, tarfile
tar, dst = sys.argv[1], sys.argv[2]
# A REGISTRY LAYER IS A TAR, sometimes gzipped. `r:*` sniffs it; the magic bytes are why this is not
# an `xz` call - and `xz` is not in the image at all, measured.
with tarfile.open(tar, "r:*") as t:
    t.extractall(dst, filter="tar")
PY
fi
log "root tree: $(du -sm "$ROOT" | cut -f1) MiB"

# --- 2. an fstab a microvm can satisfy ------------------------------------------------------
log "writing an fstab with only the filesystem that exists"
cat > "$ROOT/etc/fstab" <<'EOF'
# A microvm has ONE filesystem. The kernel argument `root=/dev/vda` mounts it; saying so here is what
# keeps `systemctl` and the kernel in agreement.
/dev/vda  /  ext4  rw,errors=remount-ro  0  1
EOF

# --- 3. a console that reaches a prompt -----------------------------------------------------
log "unlocking the console account and enabling autologin on tty1 and ttyS0"
sed -i 's/^root:[^:]*:/root::/' "$ROOT/etc/shadow"
for unit in serial-getty@ttyS0 getty@tty1; do
	mkdir -p "$ROOT/etc/systemd/system/${unit}.service.d"
	cat > "$ROOT/etc/systemd/system/${unit}.service.d/autologin.conf" <<'EOF'
[Service]
# THE AUTOLOGIN IS THE ASSERTION, not a convenience. `login: root (automatic login)` can only appear
# after systemd reached multi-user and the store's own binaries ran, which is what a step checks.
ExecStart=
ExecStart=-/sbin/agetty --autologin vmuser --noclear %I $TERM
EOF
done

# --- 4. a kernel, its modules, and an initramfs that loads virtio ----------------------------
log "installing the kernel and initramfs-tools (about 90 MiB)"
# THE IMAGE ALREADY SHIPS A `debian.sources` FILE, and MEASURED, writing `sources.list` beside it
# makes apt complain that every target is configured twice - and then installs nothing, because the
# first error it hits is about the duplicated one. The published file is correct, so it is used and
# `sources.list` is left empty.
: > "$ROOT/etc/apt/sources.list"

# THE ORIGINAL SOURCES ARE KEPT, BECAUSE THE MIRROR IS FOR THIS BUILD AND NOT FOR THE IMAGE.
#
# A guest is a system that upgrades itself. `mirrors.ustc.edu.cn` is fast FROM THIS BUILD HOST - it
# says nothing about the network the guest will run on, and baking it in would leave a machine whose
# `apt-get upgrade` is pointed at a mirror chosen for somebody else's route. So the file is copied
# aside here and put back after the install, below.
ORIG_SOURCES="$WORK/orig-debian.sources"
if [ -f "$ROOT/etc/apt/sources.list.d/debian.sources" ]; then
	cp "$ROOT/etc/apt/sources.list.d/debian.sources" "$ORIG_SOURCES"
	: > "$WORK/orig-had-sources"
else
	rm -f "$WORK/orig-had-sources"
fi
if [ ! -f "$ROOT/etc/apt/sources.list.d/debian.sources" ]; then
	printf 'deb %s/debian %s main\n' "$MIRROR" "$V" > "$ROOT/etc/apt/sources.list"
	printf 'deb %s/debian %s-updates main\n' "$MIRROR" "$V" >> "$ROOT/etc/apt/sources.list"
	printf 'deb %s/debian-security %s-security main\n' "$MIRROR" "$V" >> "$ROOT/etc/apt/sources.list"
fi

# THE MIRROR IS AN OPTION BECAUSE THE IMAGE'S DEFAULT IS 200x SLOWER FROM HERE THAN THE ALTERNATIVE.
#
# MEASURED, 10 s each through the lab's proxy, same file (`dists/trixie/main/binary-amd64/Packages.xz`):
#
#	deb.debian.org (HTTP)                34 kB/s   <- what the image's debian.sources names
#	mirrors.tuna.tsinghua.edu.cn        3.1 MB/s
#	mirrors.aliyun.com                  415 kB/s
#	mirrors.ustc.edu.cn                  26 MB/s
#
# The install is ~90 MiB of index plus ~400 MiB of packages, so at 34 kB/s it is HOURS - and the
# first run of this file sat in `apt-get update` with 4.4 MB of `Packages.xz` on disk after five
# minutes, which reads exactly like a hang. The sources are rewritable, so they are rewritten.
#
# IT STAYS `http://`, AND THAT IS THE OFFICIAL ARRANGEMENT RATHER THAN A COMPROMISE.
#
# `debian:trixie` SHIPS NO `ca-certificates`: MEASURED, `/etc/ssl` does not exist in the layer and
# `ca-certificates` is absent from its dpkg database. That is why the image's own
# `debian.sources` names `http://deb.debian.org/debian` and not https - there is nothing to verify a
# certificate with until apt has installed one, and apt cannot install one over a transport that
# needs it. Rewriting these sources to `https://` (which an earlier version of this block did) makes
# every fetch fail with
#
#	SSL connection failed: error:0A000086:SSL routines::certificate verify failed
#
# and, because `apt-get update` only WARNS, the install then proceeds against an empty package list
# and fails with fifty `Unable to locate package` lines that name the wrong cause.
#
# THE `Signed-By` LINE IS KEPT FROM THE IMAGE rather than written here: the keyring path is what makes
# apt accept the archive at all, and it authenticates the CONTENT rather than the transport. A mirror
# is a copy of the same signed archive, so an unencrypted fetch of it is verified exactly as the
# encrypted one would be.
if [ -n "$MIRROR" ]; then
	cat > "$ROOT/etc/apt/sources.list.d/debian.sources" <<SOURCES
Types: deb
URIs: ${MIRROR}/debian
Suites: ${V} ${V}-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp

Types: deb
URIs: ${MIRROR}/debian-security
Suites: ${V}-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp
SOURCES
	log "apt mirror: ${MIRROR}"
fi
cp /etc/resolv.conf "$ROOT/etc/resolv.conf" 2>/dev/null || true

# `/tmp` MUST BE WORLD-WRITABLE OR apt CANNOT UNPACK ANYTHING. MEASURED: the layer ships `/tmp` as
# 0755 root:root, and `apt-get update` then fails with
#
#	Unable to mkstemp /tmp/apt.sig.XXXXXX - GetTempFile (13: Permission denied)
#
# because the signature check drops to the unprivileged `_apt` user. A real Debian install has 1777.
chmod 1777 "$ROOT/tmp"

mount --bind /dev  "$ROOT/dev"  2>/dev/null || true
mount --bind /proc "$ROOT/proc" 2>/dev/null || true
mount --bind /sys  "$ROOT/sys"  2>/dev/null || true
# `apt` WANTS A PTY AND A CONTAINER MAY NOT BE ABLE TO GIVE ONE, AND THE FAILURE IS SILENT.
#
# MEASURED, and it cost two builds. apt prints
#
#	E: Can not write log (Is /dev/pts mounted?) - posix_openpt (2: No such file or directory)
#
# and then STOPS - after unpacking some packages. The image looks built, `dpkg -l` counts a couple of
# the new names, and the ones at the END of the list are simply absent. The first build of this file
# ended its list with `xclip pulseaudio at-spi2-core` and shipped with none of them.
#
# A bind mount of /dev does not bring /dev/pts (it is its own filesystem), and in THIS pod a separate
# `mount --bind /dev/pts` fails anyway:
#
#	mount: /tmp: bind /dev/pts failed.
#
# - the container has no SYS_ADMIN. So the pty is not the fix; telling apt not to ask for one is.
# `DPkg::Use-Pty=0` makes dpkg run maintainer scripts without a pty, which is exactly what a chroot
# without /dev/pts needs, and it changes nothing else.
mkdir -p "$ROOT/etc/apt/apt.conf.d"
cat > "$ROOT/etc/apt/apt.conf.d/99no-pty" <<'APTCONF'
// No pty is available in this chroot, and dpkg's pty is only for capturing maintainer-script output.
DPkg::Use-Pty "false";
APTCONF

env ${https_proxy:+https_proxy="$https_proxy"} ${http_proxy:+http_proxy="$http_proxy"} \
	DEBIAN_FRONTEND=noninteractive \
	DESKTOP_PKGS="$DESKTOP_PKGS" \
	chroot "$ROOT" /bin/sh -c '
		set -e
		apt-get update -qq
		# THE VIRTIO MODULES ARE THE POINT. Without virtio_blk the guest boots to
		# "ALERT! /dev/vda does not exist" because nothing ever claims the MMIO device.
		# THE BASE IS THE SAME IN BOTH VARIANTS: a kernel that finds the disk, systemd, sshd and a
		# network. `DESKTOP` expands below to add the screen stack or nothing.
		apt-get install -y -qq --no-install-recommends \
			linux-image-amd64 initramfs-tools udev systemd-sysv \
			iproute2 iputils-ping ca-certificates tzdata openssh-server \
			curl e2fsprogs passwd sudo \
			$DESKTOP_PKGS

		# AND WHY THOSE LAST FOUR - ALL OF WHICH ARRIVE THROUGH `$DESKTOP_PKGS`, SO THIS PARAGRAPH
		# DESCRIBES THE XFCE VARIANT ONLY AND IS KEPT BESIDE THE LIST IT EXPLAINS.
		#
		#	xclip             makes the clipboard readable rather than absent. probe.rs looks for
		#	                  xclip or xsel on PATH, and the first build had neither - so a desktop
		#	                  with a working clipboard reported clipboard: None.
		#	at-spi2-core      the a11y bus. probe.rs reports Atspi LAZILY - it does not probe, because
		#	                  org.a11y.Bus only appears once a client asks - so without this package
		#	                  the claim is made and nothing answers it.
		#	pulseaudio        the audio backend. There is no sound device on a microvm; the null sink
		#	pulseaudio-utils  built further down is the device, and pacat is what keeps it mixing.
		#	dbus              NOT the same package as dbus-x11. MEASURED: `dbus-x11` brings the
		#	                  daemon binary but not the configuration, so starting it answers
		#	                    Failed to open "/usr/share/dbus-1/system.conf": No such file
		#	                  and pulseaudio --system then cannot register - which reads as an
		#	                  audio failure and is a missing system bus.
		# initramfs-tools DOES NOT PULL virtio_mmio on its own: a normal machine boots from SATA.
		# All three are named so the dependency chain is explicit and update-initramfs records it.
		for m in virtio virtio_ring virtio_mmio virtio_pci virtio_blk ext4; do
			grep -qx "$m" /etc/initramfs-tools/modules 2>/dev/null || echo "$m" >> /etc/initramfs-tools/modules
		done
		update-initramfs -u -k all
		# THE PROOF THIS STEP WORKED, checked inside the tree rather than hoped for afterwards.
		command -v lsinitramfs >/dev/null && lsinitramfs /boot/initrd.img-* | grep -q virtio_blk \
			|| echo "WARNING: virtio_blk is not in the generated initramfs"
	'

# AND THE MIRROR GOES BACK TO WHAT THE IMAGE SHIPPED, because it was for this build only.
#
# MEASURED: the difference is 26 MB/s against 34 kB/s HERE, which is the difference between minutes
# and hours for 500 MB of packages - and zero difference to a guest on another network. Leaving
# `mirrors.ustc.edu.cn` in the tree would make every future `apt` the guest runs depend on a host
# chosen for this build machine's route.
if [ -f "$WORK/orig-had-sources" ]; then
	cp "$ORIG_SOURCES" "$ROOT/etc/apt/sources.list.d/debian.sources"
	log "apt sources restored to the image's own"
else
	rm -f "$ROOT/etc/apt/sources.list.d/debian.sources" "$ROOT/etc/apt/sources.list"
	log "apt sources removed, because the image shipped none"
fi

# --- 2b. THE ACCOUNT THE DRIVER LOGS IN AS ---------------------------------------------
#
# MEASURED: the daemon dials `vmuser` with password `admin` - `walk.File.SSHUser` defaults to
# `vmuser` (see walk.go) and `--password` defaults to `admin` (see cmd/easyvm/main.go) - and this image
# had NEITHER: no account under UID 1000 at all, and `root::` (an empty password) which sshd refuses
# because `PermitEmptyPasswords no` is Debian's default.
#
# THE SYMPTOM WAS NOT AN SSH ERROR. `/api/state` reported `ssh_ready: false` forever while port 22
# answered and the machine was healthy, so every question about the guest's network came down to a
# channel that could not be opened. Nothing in `xfce.walk` uses SSH, which is why the mismatch
# survived this long.
#
# `--gecos` AND `chpasswd` RATHER THAN `useradd -p`: the hash form depends on the shadow suite's
# current algorithm, and `chpasswd` states the intent - this account's password is this string -
# without this script deciding how it is hashed.
log "creating the vmuser account the driver logs in as"
chroot "$ROOT" /bin/sh -c 'id vmuser >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo vmuser' 2>/dev/null || \
	chroot "$ROOT" /bin/sh -c 'id vmuser >/dev/null 2>&1 || useradd -m -s /bin/bash vmuser'
printf 'vmuser:admin\n' | chroot "$ROOT" chpasswd
# A SUDO RULE FOR A GROUP THAT MAY NOT EXIST: `-G sudo` fails on an image without it, and the second
# `useradd` above covers that. This writes the rule only when the package provided the directory, so a
# guest without sudo is not given a file sudo will never read.
if [ -d "$ROOT/etc/sudoers.d" ]; then
	printf 'vmuser ALL=(ALL) NOPASSWD:ALL\n' > "$ROOT/etc/sudoers.d/90-vmuser"
	chmod 0440 "$ROOT/etc/sudoers.d/90-vmuser"
fi

# THE SSHD SETTINGS ARE STATED EVEN THOUGH THE DEFAULTS ALREADY ALLOW THIS.
#
# Debian's `sshd_config` ships `#PasswordAuthentication yes` commented, so the compiled-in default
# applies and password login works - TODAY. A drop-in is used rather than editing the file because
# `sshd_config` includes `sshd_config.d/*.conf` first, and a drop-in survives a package upgrade that
# rewrites the main file.
#
# `PermitRootLogin` IS DELIBERATELY NOT ENABLED. Nothing needs to log in as root over ssh: the console
# autologins root, `vmuser` has NOPASSWD sudo, and `root::` (an empty password) is a string that must
# not become a remote login just because sshd was told to accept passwords.
mkdir -p "$ROOT/etc/ssh/sshd_config.d"
cat > "$ROOT/etc/ssh/sshd_config.d/10-easyvm.conf" <<'SSHD'
# Password authentication is how the driver logs in as vmuser; see walk.UserForPaths.
PasswordAuthentication yes
# Keep the default, which refuses a password for root while allowing the account itself.
PermitRootLogin prohibit-password
UsePAM yes
SSHD

# THE WHOLE SCREEN STACK IS ONE BRANCH, because none of it can work without the others: a session
# with no X server draws nothing, easystream with no session has no pixels to read, and PulseAudio
# with no null sink has no device. `DESKTOP=0` skips all of it and the tree stays a systemd box
# with sshd - which is what `debian-minimal` is.
if [ "$DESKTOP" = "1" ]; then
# --- 4b. THE DESKTOP, AND THE STREAM THAT CARRIES IT ----------------------------------------
#
# MEASURED, AND THE REASON THE WHOLE DESIGN IS SHAPED THIS WAY: a microvm has NO FIRMWARE and NO
# PCIe, so it has neither a DRM node nor /dev/fb0. An X server cannot run on hardware that is not
# there - `modesetting` finds no screen and `fbdev` finds no framebuffer.
#
# `Xvfb` renders into the process's OWN MEMORY and needs no graphics device at all. That is why this
# works where Xorg cannot, and it is the same choice e2b's desktop template makes (`xvfb` +
# `xfce4`). easystream then reads those pixels through the X protocol (XSHM/XGetImage) and encodes
# H.264 into `est://`, which easyvm forwards to a browser.
#
# NOTHING HERE NEEDS A GPU, AND `x11vnc` IS DELIBERATELY ABSENT: easystream is the thing that reads
# the screen, and two clients competing for the same display is one more process to explain.
# THE DEBIAN 13 PACKAGE, NOT THE UNIVERSAL BINARY.
#
# `release-matrix.yml` BUILDS ONE PACKAGE PER LIBRARY BASE and publishes every one of them. The
# reason is in that file and it is not a preference: libx264 puts its ABI in the SONAME *and* in every
# exported symbol, and glibc is a second, independent floor. A binary built on Ubuntu 24.04 links
# against glibc 2.39 and x264 164; Debian 13 has glibc 2.41 and x264 164, so it happens to load - and
# "happens to" is the whole problem, because the next base that moves breaks it silently, at symbol
# resolution, on a guest that boots to a dead frame.
#
# SO THE ARTIFACT NAMES ITS BASE and we take ours. `easystream_<ver>_amd64-debian-13.deb` is built in
# `debian:13` against that image's own apt, which is the only way to be sure the two agree.
#
# IT IS A PACKAGE RATHER THAN A BARE FILE because nfpm also records `Depends:` - libx264-164,
# libyuv0, libxcb-xtest0 - so a missing library is a install error here instead of a loader error in
# the guest. The packages the unit files need are installed by the apt line above.
# THE FILENAME IS DERIVED FROM THE VERSION, AND IT CHANGED. `nfpm` writes
# `easystream_<version>_amd64.deb`; `ci/package.sh` then appends the base, giving
# `easystream_0.10.2_amd64-debian-13.deb`. The old name here was
# `easystream_main_amd64-debian-13.deb`, from the bare-executable era, and it 404s against every
# release after v0.10.2 - so the version is stripped of its leading `v` and interpolated rather
# than written out twice.
ES_VERSION="${EAZYSTREAM_VERSION:-v0.10.2}"
ES_DEB="easystream_${ES_VERSION#v}_amd64-debian-13.deb"
if [ ! -x "$ROOT/usr/bin/easystream" ]; then
	curl -fsSL --retry 3 --max-time 300 \
		-o "$WORK/$ES_DEB" \
		"https://github.com/easydev-org/easystream/releases/download/${ES_VERSION}/${ES_DEB}"
	# `dpkg-deb -x` INTO THE TREE, which is how the package's `/usr/bin/easystream` lands where the
	# unit expects it without an apt database to install against.
	dpkg-deb -x "$WORK/$ES_DEB" "$ROOT"
	chmod 0755 "$ROOT/usr/bin/easystream"
fi
# AND THE PROOF IT CAN ACTUALLY LOAD, taken here rather than discovered on a guest that boots to a
# dead frame: the dynamic loader is run against the tree's own libs.
if command -v ldd >/dev/null 2>&1; then
	chroot "$ROOT" ldd /usr/bin/easystream 2>&1 | grep -q "not found" \
		&& echo "WARNING: easystream has unresolved libraries: $(chroot "$ROOT" ldd /usr/bin/easystream 2>&1 | grep 'not found' | tr '\n' ' ')" \
		|| echo "easystream: all libraries resolve"
fi

cat > "$ROOT/etc/systemd/system/xvfb.service" <<'UNIT'
[Unit]
Description=Xvfb, an in-memory framebuffer
After=local-fs.target

[Service]
Type=simple
# THE WHOLE X SESSION RUNS AS vmuser, NOT root.
#
# THE REASON IS THE WAYLAND SIDE OF THIS SAME IMAGE FAMILY: PipeWire refuses root
# (`ConditionUser=!root`), so a desktop session owned by root can never be extended into
# one that captures or plays audio. MEASURED on the KDE variant, where `systemctl --user
# start pipewire` answered "inactive".
#
# `-ac` disables access control: the port is not reachable from anywhere but this machine,
# and with the server and its clients both under vmuser the cookie dance would be for an
# audience of one.
User=vmuser
ExecStart=/usr/bin/Xvfb :0 -screen 0 1024x768x24 -ac -nolisten tcp
Restart=always
RestartSec=2
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT

cat > "$ROOT/etc/systemd/system/xfce.service" <<'UNIT'
[Unit]
Description=the xfce session on Xvfb :0
After=xvfb.service
Requires=xvfb.service

[Service]
Type=simple
User=vmuser
Environment=DISPLAY=:0
Environment=HOME=/home/vmuser
Environment=XDG_SESSION_TYPE=x11
# `xfce4-session` AND NOT `startxfce4`. MEASURED: `startxfce4` first looks for a FREE display and,
# finding ours already up, answers `X server already running on display :0` and exits. It is a
# launcher for a display that is not running yet; we are that launcher.
ExecStart=/usr/bin/xfce4-session
Restart=always
RestartSec=3
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT

cat > "$ROOT/etc/systemd/system/easystream.service" <<'UNIT'
[Unit]
Description=easystream: X11 capture, H.264, est://
After=xfce.service
Requires=xvfb.service
# THE AUDIO PIPE MUST EXIST BEFORE THE PROBE, AND IT IS A WEAK DEPENDENCY ON PURPOSE.
#
# MEASURED, and it is a race rather than a setting: `audio: pulse probing` ran at 3.144s while
# `pulseaudio.service` finished at 3.104s and `vsink.service` had not loaded the null sink yet. The
# probe reads one 20ms frame and gives up if the sink is not mixing, so about half the boots
# reported `audio: pulse probe -> false` and the Hello carried `hasAudio = 0` - intermittently, which
# is the worst kind of report.
#
# `Wants=` AND NOT `Requires=`: a guest with no audio configured must still stream its screen, and
# `Requires=` would refuse to start easystream at all when the sound stack fails. `After=` is what
# puts the ordering in place - it only says "if both are starting, audio goes first".
#
# THIS IS STILL A BEST-EFFORT ORDERING. `After=` waits for `vsink.service` to be DONE, and vsink is a
# oneshot that `pactl load-module` finishes, so the sink exists when easystream starts. What is not
# guaranteed is that `vsink-silence` is pushing bytes yet - so a probe that lands in that window
# still sees a sink with no mix. The daemon retries its probe, which is why the failure is
# intermittent rather than permanent.
Wants=pulseaudio.service vsink.service vsink-silence.service
After=pulseaudio.service vsink.service vsink-silence.service

[Service]
Type=simple
User=vmuser
Environment=DISPLAY=:0
Environment=HOME=/home/vmuser
Environment=EAZYSTREAM_PORT=48079
Environment=EAZYSTREAM_HTTP_PORT=48080
ExecStart=/usr/bin/easystream
Restart=always
RestartSec=3
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT

# --- 4c. THE SOUND CARD A MICROVM DOES NOT HAVE ------------------------------------------------
#
# A microvm has no audio device, and `pcie=off` means no HDA controller either - so `audio.rs` would
# find no backend and every Hello would say `hasAudio = 0`. MEASURED on the first build:
#
#	easystream[314]: audio: no working capture backend
#
# PULSEAUDIO'S NULL SINK IS THE DEVICE. It is a sink that mixes into nothing and exposes the mix as
# `vsink.monitor` - which is exactly the source name `audio.rs` looks for by default
# (`EAZYSTREAM_AUDIO_SOURCE`, defaulting to "vsink.monitor").
#
# AND THE MONITOR MUST BE MIXING SOMETHING. A null sink with no input has no mix, and
# `parec --device=vsink.monitor` blocks without producing a byte; `audio.rs` proves a backend by
# reading one 20 ms frame within 4 seconds, so it would report "present but produced no data" and
# fall through to None. `pacat` playing /dev/zero keeps the mix alive, and any real audio the desktop
# later produces sums into the same one.
# THE SYSTEM BUS, WHICH `pulseaudio --system` REQUIRES AND A BARE IMAGE DOES NOT START.
cat > "$ROOT/etc/systemd/system/dbus.service" <<'UNIT'
[Unit]
Description=the system message bus
[Service]
Type=simple
ExecStart=/usr/bin/dbus-daemon --system --nofork --nopidfile
Restart=always
RestartSec=2
StandardOutput=journal+console
StandardError=journal+console
[Install]
WantedBy=multi-user.target
UNIT

cat > "$ROOT/etc/systemd/system/pulseaudio.service" <<'UNIT'
[Unit]
Description=PulseAudio in system mode, because there is no session and no seat
# D-BUS IS NOT OPTIONAL FOR --system, AND ITS ABSENCE LOOKS LIKE AN AUDIO PROBLEM.
#
# MEASURED on the first build with pulseaudio installed:
#
#	pulseaudio[312]: authkey.c: Failed to open cookie file ...
#	pulseaudio[312]: main.c: Unable to contact D-Bus:
#	                 org.freedesktop.DBus.Error.FileNotFound: Failed to connect to socket
#	                 /run/dbus/system_bus_socket: No such file or directory
#
# The daemon starts and then cannot register, so `pactl` has no server to talk to, the null sink is
# never created, `parec` records nothing, and `audio.rs` reports "present but produced no data".
# Every one of those messages points at audio; the cause is the bus.
Requires=dbus.service
After=sound.target dbus.service

[Service]
# `Type=notify`, BECAUSE `Type=simple` ANNOUNCES "READY" AT `fork()` AND THE SOCKET IS NOT UP YET.
#
# MEASURED, and it is why `audio: pulse probe -> false` came back on a guest whose PulseAudio was
# configured correctly: `vsink.service` requires `pulseaudio.service`, so systemd started `pactl`
# the instant the process existed - and the console shows the order plainly.
#
#	3.032  Started pulseaudio.service
#	3.070  pulseaudio[316]: authkey.c: Failed to open cookie file ...    <- still initialising
#	3.3    Failed to start vsink.service - a null sink named vsink       <- pactl, too early
#	3.487  (pulseaudio finishes loading its modules)
#
# `pactl` could not connect, the null sink was never created, `parec --device=vsink.monitor` recorded
# nothing, and `audio.rs` reported a backend that is "present but produced no data" - which names the
# audio system for a missing socket. `Requires=` orders STARTUP, not READINESS.
#
# THE BINARY DOES SEND THE NOTIFICATION, so this is not a guess: MEASURED, `strings
# /usr/bin/pulseaudio` contains `sd_notify` and `READY=1`, and it is linked against `libsystemd.so.0`
# precisely so it can. `NotifyAccess=all` is needed because the notification does not come from the
# main process in every version; it costs nothing when it does.
Type=notify
NotifyAccess=all
# SYSTEM MODE IS THE POINT: a microvm runs no login session, so there is no user daemon to connect
# to and no XDG_RUNTIME_DIR. `--exit-idle-time=-1` keeps it alive with no clients.
ExecStart=/usr/bin/pulseaudio --system --disallow-exit --disallow-module-loading=0 --exit-idle-time=-1 --no-cpu-limit
Restart=always
RestartSec=2
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT

# `--system` REFUSES A CLIENT THAT IS NOT IN `pulse-access`, AND THAT READS AS A DEAD DAEMON.
#
# MEASURED BEHAVIOUR of PulseAudio in system mode: `pactl` answers
#
#	Connection failure: Access denied
#
# while `systemctl status pulseaudio` says active (running). Root is not special here - the check is
# group membership - so the group has to be stated. The package creates it; this puts root in it.
# `gpasswd` HERE WOULD EDIT THE HOST'S /etc/group, NOT THE IMAGE'S.
#
# The first version ran it in the outer shell and it silently did nothing to "$ROOT": `gpasswd`
# resolves its group file from the running system. MEASURED after that build:
#
#	pulseaudio[311]: protocol-native.c: Denied access to client with invalid authentication data
#
# from `pactl` - the daemon was up, the socket existed, and the client was refused because root was
# not in the image's pulse-access group. The edit has to happen against the tree being built.
chroot "$ROOT" gpasswd -a root pulse-access >/dev/null 2>&1 || true
# AND vmuser, BECAUSE THE DESKTOP MOVED THERE. easystream is the client that reads audio
# and it now runs as vmuser; without this it is refused with
#
#	pulseaudio[311]: protocol-native.c: Denied access to client with invalid authentication data
#
# which is the same failure this line was written for, one user later.
chroot "$ROOT" gpasswd -a vmuser pulse-access >/dev/null 2>&1 || true

# THE UNIX SOCKET MUST ACCEPT AN ANONYMOUS CLIENT, AND THE DEFAULT DOES NOT.
#
# MEASURED, after dbus and the group were both sorted:
#
#	pulseaudio[311]: protocol-native.c: Denied access to client with invalid authentication data
#
# `system.pa` ships `load-module module-native-protocol-unix` with no `auth-anonymous`, which means
# the daemon wants a cookie - and a cookie is per-user session state that a system daemon and a root
# `pactl` do not share. `auth-anonymous=1` is the documented setting for exactly this case: a socket
# that is only reachable by processes already inside the machine.
#
# IT IS NOT A SECURITY RELAXATION WORTH ARGUING ABOUT HERE. The socket lives at /run/pulse/native
# inside a microvm whose only console is the one easyvm owns; anyone who can open it can already read
# the disk.
python3 - "$ROOT" <<'PYSETUP'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
pa = root / "etc/pulse/system.pa"
if pa.exists():
    t = pa.read_text()
    if "auth-anonymous=1" not in t:
        t = t.replace("load-module module-native-protocol-unix",
                      "load-module module-native-protocol-unix auth-anonymous=1", 1)
        pa.write_text(t)
PYSETUP

# THE SINK AND THE SILENCE ARE TWO UNITS, BECAUSE THEY HAVE TWO LIFETIMES.
#
# `pactl load-module` returns as soon as the module is loaded and the sink lives inside the daemon -
# so a unit that only loads it is a ONESHOT that stays "active (exited)" forever, which is correct.
# `pacat` is the opposite: it must keep RUNNING or the monitor stops mixing. Folding the two into one
# oneshot was written first and is wrong - systemd would consider the unit finished while its
# ExecStart had a child that never exits.
cat > "$ROOT/etc/systemd/system/vsink.service" <<'UNIT'
[Unit]
Description=a null sink named vsink
After=pulseaudio.service
Requires=pulseaudio.service

[Service]
Type=oneshot
RemainAfterExit=yes
# PULSE_SERVER NAMES THE SYSTEM DAEMON'S SOCKET. Without it `pactl` tries a per-user socket that does
# not exist and answers "Connection refused", which reads as "pulseaudio is not running".
Environment=PULSE_SERVER=unix:/run/pulse/native
# `pactl`'s REFUSAL MUST REACH THE CONSOLE. MEASURED: without this the unit failed with
# `See 'systemctl status vsink.service' for details` and the reason - a connection error - existed
# only in the journal, which on this guest is not readable while the machine is booting.
StandardOutput=journal+console
StandardError=journal+console
ExecStart=/usr/bin/pactl load-module module-null-sink sink_name=vsink sink_properties=device.description=vsink

[Install]
WantedBy=multi-user.target
UNIT

cat > "$ROOT/etc/systemd/system/vsink-silence.service" <<'UNIT'
[Unit]
Description=silence into vsink, so its monitor has a mix to record
After=vsink.service
Requires=vsink.service

[Service]
# `Type=exec` RATHER THAN `simple`: systemd reports the unit started once `pacat` has been EXECUTED,
# which is the earliest point at which it can have written anything. `simple` reports it at the
# `fork()`, before the binary is loaded, and `easystream.service` has `After=vsink-silence.service` -
# so with `simple` the ordering could be satisfied while no audio was flowing yet.
#
# THERE WAS AN `ExecStartPost` HERE AND IT WAS REMOVED. It polled `pactl list sink-inputs`, which
# blocks when the PulseAudio socket is not accepting yet - and because an `ExecStartPost` runs on the
# unit's own start path, MEASURED on a boot: the whole guest wedged, with `jbd2/vda-8`, `kworker` and
# `systemd-journal` each reported `blocked for more than 120 seconds` and then 240. A probe that
# cannot answer must never be able to stop the disk from being written.
#
# SO THE ORDERING IS THE WHOLE FIX, and `Type=exec` is the part of it that can be stated safely.
Type=exec
Environment=PULSE_SERVER=unix:/run/pulse/native
# A MONITOR WITH NOTHING PLAYING PRODUCES NO BYTES, and `audio.rs` proves a backend by reading one
# 20 ms frame within 4 seconds. Without this stream the probe times out and the daemon advertises
# `audio: None` on a guest whose sink is perfectly configured.
#
# `--raw /dev/zero`: pacat reads a file rather than a pipe, so the child throttles itself against the
# sink instead of against a writer in this image that would have to remember to keep writing.
ExecStart=/usr/bin/pacat --device=vsink --format=s16le --rate=48000 --channels=2 --raw /dev/zero
Restart=always
RestartSec=3
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT

# --- 4c2. THE BROWSER'S EXPECTATION THIS MACHINE CANNOT MEET -----------------------------------
#
# MEASURED in the guest's Chromium, on first load:
#
#	ContextResult::kFatalFailure: WebGL1 blocklisted
#	ContextResult::kFatalFailure: WebGL2 blocklisted
#
# THAT IS HARMLESS AND NOTHING IS SET FOR IT. WebGL is blocklisted because a microvm has no GPU - no
# `/dev/dri`, no adapter - so Chromium renders in software. The desktop, the terminal and the file
# manager are unaffected; only a page that needs 3D notices. Forcing WebGL on a machine without a GPU
# would trade a console line for a slower, broken one.
#
# THE OTHER ERROR THIS FILE USED TO ANSWER IS GONE. `net_error -100` on every HTTPS page was HTTP/3:
# a server answers over TCP with `alt-svc: h3=":443"`, the browser tries QUIC on UDP 443, and a
# CONNECT tunnel cannot carry a datagram. That was worked around here by disabling QUIC in the
# browser, which is no longer a workaround but a REGRESSION: the daemon now proxies the guest's UDP
# through a tun device (see `internal/net/udprelay.go`), MEASURED as `HTTP/3 200` inside a running
# guest. A browser told to refuse QUIC would not use the path that now exists.

fi

# --- 4d. GROW INTO THE DISK, ONCE, BECAUSE THE IMAGE SIZE IS A GUESS AND THE DISK IS NOT -----
#
# THE PROBLEM THIS SOLVES: the image is written with a fixed 8 GiB of headroom, which is a guess about
# what somebody will install. A bigger disk handed to a smaller filesystem wastes it, and there is no
# way for the daemon to resize a filesystem it does not understand.
#
# THE DISK HAS NO PARTITION TABLE - `mke2fs -d` wrote the filesystem directly - so growing it is
# `resize2fs` against the whole device, with no partition to move and no `growpart` needed. That is
# why this is four lines rather than the usual cloud-init dance.
#
# IT RUNS ONCE AND RECORDS THAT IT DID. `ConditionPathExists` against the stamp is what makes it
# idempotent: a second boot skips the unit entirely instead of resizing a filesystem that is in use.
#
# IT IS ALSO BEST-EFFORT. `-` before `resize2fs` means a failure does not fail the unit, because a
# guest that cannot grow should still boot to a working desktop - a full disk is a worse problem than
# a small one, and neither is a reason to refuse to start X.
cat > "$ROOT/etc/systemd/system/growfs.service" <<'UNIT'
[Unit]
Description=grow the root filesystem into the disk it was given
# BEFORE ANYTHING WRITES, AND NOT `local-fs.target`: resizing a filesystem that other units are
# already using is how a guest loses its data. `systemd-remount-fs` has already remounted `/` rw by
# this point, which `resize2fs` requires.
DefaultDependencies=no
After=systemd-remount-fs.service
Before=local-fs.target shutdown.target
ConditionPathExists=!/var/lib/growfs-done

[Service]
Type=oneshot
RemainAfterExit=yes
# `|| true` IS NOT LAZINESS: /dev/vda already holds the largest filesystem this image needs, so a
# failed grow is the normal case on a disk that was never enlarged.
ExecStart=/bin/sh -c 'resize2fs /dev/vda 2>/dev/null || true; touch /var/lib/growfs-done'
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT

# THE ONE UNIT EVERY VARIANT WANTS. growfs is the disk growing into the size the daemon handed it,
# and without it a doubled disk keeps its old filesystem.
#
# `dbus` IS NOT HERE, because the package that provides it is in `$DESKTOP_PKGS`: enabling a unit
# whose file does not exist is not an error systemd reports, it is a job that silently does not
# exist, and it would read in the tree as if the bus were configured.
for unit in growfs; do
	ln -sf "/etc/systemd/system/$unit.service" \
		"$ROOT/etc/systemd/system/multi-user.target.wants/$unit.service"
done

# THE SCREEN'S UNITS, ONLY WHERE THERE IS A SCREEN. A `WantedBy` symlink to a unit file that was
# never written is not an error systemd reports - it is a job that silently does not exist - so
# leaving these enabled in the minimal image would look fine and mean nothing.
if [ "$DESKTOP" = "1" ]; then
	for unit in dbus xvfb xfce easystream pulseaudio vsink vsink-silence; do
		ln -sf "/etc/systemd/system/$unit.service" \
			"$ROOT/etc/systemd/system/multi-user.target.wants/$unit.service"
	done
fi


# --- 4a. THE GUEST'S NETWORK ------------------------------------------------------------------
#
# A GUEST WITH NO NETWORK CONFIGURATION GETS NO ADDRESS, AND THAT IS WHAT HAPPENED.
#
# MEASURED on the deployed pod: the tap was up, dnsmasq was running, and the bridge's ARP table
# showed
#
#	172.30.0.2 FAILED
#
# because nothing inside the guest ever asked for a lease. The console had no network line at all,
# while `easystream` had been listening on 0.0.0.0:48080 the whole time - with no address for anyone
# to reach it on.
#
# THE DEBIAN CONTAINER IMAGE SHIPS NO NETWORK CONFIG ON PURPOSE: a container is handed an interface
# by its runtime. A VM is not. Its tap is a bare ethernet segment and the guest has to run DHCP over
# it.
#
# THIS SITS OUTSIDE THE `chroot ... -c '...'` ABOVE ON PURPOSE: that block is a single-quoted shell
# string, and a heredoc inside it closes the quote early and turns the rest of the script into
# commands. It did, and the symptom was a line of prose being executed:
#
#	# `Xvfb` renders into the processs: not found
mkdir -p "$ROOT/etc/systemd/network"
cat > "$ROOT/etc/systemd/network/20-wired.network" <<'NET'
[Match]
Name=en* eth*

[Network]
DHCP=yes

[DHCPv4]
# `UseDNS=no` BECAUSE `/etc/resolv.conf` IS WRITTEN ONCE AND NAMES THE BRIDGE.
#
# networkd rewrites `/etc/resolv.conf` when DHCP hands it DNS servers, and the lease's `dns-server`
# option IS 172.30.0.1 - so with `yes` the file would be rewritten to the same address and nothing
# would break. It is `no` anyway so that there is exactly ONE writer: a static file the image
# controls. Two things writing the same file is how the original kept the dangling symlink: the
# image's link stayed because networkd did not consider itself its owner.
UseDNS=no
NET

# `systemctl enable` CANNOT RUN IN A CHROOT WITH NO /proc AND NO PID 1: it prints
# `/proc/ is not mounted. This is not a supported mode of operation.` and does nothing. These are the
# links it would have made, written directly - which is what the rest of this script already does for
# its own units.
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants" \
         "$ROOT/etc/systemd/system/sockets.target.wants"
ln -sf /usr/lib/systemd/system/systemd-networkd.service \
	"$ROOT/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
ln -sf /usr/lib/systemd/system/systemd-networkd.socket \
	"$ROOT/etc/systemd/system/sockets.target.wants/systemd-networkd.socket"
# THE RESOLVER IS STATIC AND NAMES THE BRIDGE, BECAUSE `systemd-resolved` CANNOT BOOTSTRAP HERE.
#
# MEASURED: this image shipped `systemd-resolved.service` enabled plus
# `/etc/resolv.conf -> /run/systemd/resolve/stub-resolv.conf`. `stub-resolv.conf` is written BY
# resolved once it is up, and resolved reads `/etc/resolv.conf` for its upstream list - which was the
# dangling symlink to its own output. The result on every boot was `cannot resolve host` for every
# name, while the pod beside it resolved normally.
#
# IT IS ALSO NOT NEEDED. The bridge runs dnsmasq, which answers the guest's queries and forwards them
# to the cluster resolver it was configured with (see `/tmp/easyvm-dnsmasq.conf`); so the DHCP lease
# already tells the guest `option:dns-server 172.30.0.1` and the only thing missing was a file naming
# it. A static file cannot fail to start, and it cannot depend on a daemon whose output it feeds.
#
# THE ADDRESS IS THE BRIDGE AND NOT A PUBLIC RESOLVER, because it is the only DNS the guest can
# reach: 172.18.0.10 (the cluster's) is outside the guest's /24 and has no route from it.
rm -f "$ROOT/etc/systemd/system/multi-user.target.wants/systemd-resolved.service"
rm -f "$ROOT/etc/resolv.conf"
cat > "$ROOT/etc/resolv.conf" <<'RESOLV'
# The bridge runs dnsmasq for this guest; it forwards to the cluster's resolver, which the guest
# cannot reach itself. See easyvm's dnsmasq configuration for why.
nameserver 172.30.0.1
options edns0
RESOLV

umount "$ROOT/sys" 2>/dev/null || true
umount "$ROOT/proc" 2>/dev/null || true
umount "$ROOT/dev" 2>/dev/null || true

# --- 5. write the disk ----------------------------------------------------------------------
#
# THE HEADROOM IS 8 GiB AND IT COSTS ALMOST NOTHING, BECAUSE QCOW2 IS SPARSE.
#
# MEASURED: this was `+ 250`, which produced a 1.32 GiB virtual disk holding a 1097 MiB tree - 250 MiB
# of free space on a guest whose desktop is already installed. Installing anything substantial there
# fails with
#
#	Space needed: 473 MB / 100 MB available
#
# which reads as "this image cannot install packages" and is exactly what `+ 250` means.
#
# THE COST OF A BIGGER VIRTUAL SIZE IS ZERO UNTIL IT IS WRITTEN: the same image measured 1.32 GiB
# virtual and 502 MiB in the file, because qcow2 only stores clusters that were touched. A guest that
# never fills 8 GiB never pays for it; one that does gets to install things.
#
# AND `resize2fs` LETS IT GROW FURTHER WITHOUT REBUILDING. The disk is a whole-disk ext4 with no
# partition table (`mke2fs -d` writes the filesystem directly), so growing it is one command against
# `/dev/vda` - no partition to move. `e2fsprogs` is installed above so the guest HAS that command, and
# `growfs.service` runs it once at first boot in case a future image is handed a larger disk.
# 64 GiB, FIXED. The guest grows its filesystem into the disk with `growfs.service`,
# so the virtual size is a POLICY decision and not a build artefact: qcow2 stores only
# clusters that were written, so a large disk costs nothing until somebody fills it,
# and an operator can install a toolchain or a desktop without rebuilding the image.
SIZE=65536
log "writing a ${SIZE} MiB ext4 image"
rm -f "$WORK/rootfs.raw"
truncate -s "${SIZE}M" "$WORK/rootfs.raw"
mke2fs -q -F -t ext4 -d "$ROOT" "$WORK/rootfs.raw"
qemu-img convert -f raw -O qcow2 -c "$WORK/rootfs.raw" "$OUT/debian.qcow2"

# --- 6. the two files the boot step names ---------------------------------------------------
KVER=$(ls "$ROOT/lib/modules" | head -1)
log "kernel $KVER"
cp "$ROOT/boot/vmlinuz-$KVER" "$OUT/debian-vmlinuz"
cp "$ROOT/boot/initrd.img-$KVER" "$OUT/debian-initramfs"

log "done:"
ls -l "$OUT/debian-vmlinuz" "$OUT/debian-initramfs" "$OUT/debian.qcow2"
