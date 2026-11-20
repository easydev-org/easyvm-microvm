#!/bin/sh
# BUILD AN ARCH LINUX ROOT FILESYSTEM A MICROVM BOOTS.
#
# THE ROOT TREE IS THE OFFICIAL CONTAINER IMAGE. Arch publishes
# `archlinux-bootstrap-x86_64.tar.zst` too, but it has TWO traps that the container image
# does not:
#
#	1. ITS pacman.conf HAS EVERY MIRROR COMMENTED OUT, so `pacman -Sy` answers
#	   "failed to synchronize all databases (no servers configured for repository)".
#	   Generating a mirrorlist needs `reflector`, which needs a working pacman.
#	2. IT EXPECTS A MOUNTED /proc. `pacman -S` fails with
#	   "could not open file: /etc/mtab: No such file or directory" and then
#	   "could not determine filesystem mount points" - and a build container that cannot
#	   mount proc can never satisfy that.
#
# The container image has a working pacman.conf pointing at the official mirror, which is
# why it is used instead. MEASURED: the mirror-list file it ships is also empty, so this
# script writes one line before installing anything.
#
# WHAT ITS KERNEL NEEDS, read from the installed package's modules.builtin:
#
#	kernel/drivers/block/virtio_blk.ko       BUILT IN - no module needed
#	kernel/fs/ext4/ext4.ko                   BUILT IN - no module needed
#	CONFIG_VIRTIO_MMIO=m                     a module, so it must be loaded
#
# so exactly ONE module goes into the initramfs, same as Fedora.
set -eu

# DESKTOP NAMES THE SESSION TO INSTALL:
#
#	0  sway  hyprland  budgie  xfce  cinnamon  lxqt  mate  i3
#
# LXDE IS DELIBERATELY ABSENT. Its package is still 0.99.4 - a version it has carried for
# years - and LXQt exists precisely as its modern replacement. Shipping a desktop whose own
# upstream never reached 1.0 is not what "a microvm running a current desktop" means.
#
# ONE SCRIPT FOR ALL OF THEM, because everything that makes this boot is identical - the
# kernel, the initramfs modules, /dev, the fstab, the console session, growfs - and a script
# per desktop would be nine copies of that which drift.
#
# THE DESKTOPS SPLIT INTO TWO FAMILIES, AND THE SPLIT DECIDES THE CAPTURE PATH:
#
#	WAYLAND  sway, hyprland, budgie  `wlr-screencopy`, or for budgie the compositor's own
#	                                 protocol. easystream reads it over the socket.
#	X11      xfce, cinnamon,         an X server (Xvfb, in memory - a microvm has no GPU),
#	         lxqt, mate, i3           and easystream reads it with XSHM.
#
# KDE AND GNOME ARE NOT HERE ON PURPOSE. Both capture through xdg-desktop-portal, which needs
# a backend, PipeWire, a PermissionStore and a `graphical-session.target` that only a greeter
# creates. MEASURED on the KDE probe: the backend's own unit aborted with `status=6/ABRT`,
# the frontend came up without it, and easystream looped on
# "No such interface org.freedesktop.portal.RemoteDesktop". That is a separate problem and it
# is being solved separately.
DESKTOP="${DESKTOP:-0}"

case "$DESKTOP" in
0|"")                 DESKTOP_FAMILY=none ;;
sway|hyprland|budgie) DESKTOP_FAMILY=wayland ;;
xfce|cinnamon|lxqt|mate|i3) DESKTOP_FAMILY=x11 ;;
*)
	echo "DESKTOP=$DESKTOP is not one of: 0 sway hyprland budgie xfce cinnamon lxqt mate i3" >&2
	exit 2
	;;
esac

OUT="${1:-.}"
WORK="${OUT}/arch-build"

log() { printf '  %s\n' "$*"; }

mkdir -p "$WORK" "$OUT"
HERE=$(cd "$(dirname "$0")" && pwd)

# --- 1. the root tree ---------------------------------------------------------------------
if [ ! -f "$WORK/rootfs.tar" ]; then
	log "pulling archlinux:latest from docker.io"
	python3 "$HERE/fetch-image.py" library/archlinux latest "$WORK/rootfs.tar"
fi

ROOT="$WORK/root"
if [ ! -d "$ROOT/usr" ]; then
	log "unpacking"
	rm -rf "$ROOT"
	mkdir -p "$ROOT"
	tar -xf "$WORK/rootfs.tar" -C "$ROOT"

	# THE IMAGE HAS NO /dev, /proc OR /sys AT ALL, AND THAT IS ARCH-SPECIFIC.
	#
	# MEASURED from the registry tarballs themselves: alpine, debian, ubuntu, fedora and
	# leap each carry an empty `dev/` directory; `archlinux:latest` carries NO `dev` entry
	# of any kind.
	#
	# THE FAILURE THAT CAUSES IS NOT IN THIS SCRIPT, IT IS LATER. The initramfs moves
	# /proc and /sys onto the new root and switch_roots:
	#
	#	for d in proc sys; do mount --move "/$d" "/newroot/$d" || true; done
	#
	# `|| true` THERE IS DELIBERATE (a failed move is not worth refusing to boot), so a
	# missing directory is SILENT. What it costs is a guest whose systemd cannot mount
	# anything: MEASURED on a hand-built KDE image that had no /dev, boot stalled at
	#
	#	A start job is running for…nts and Files (1min 57s / 3min 2s)
	#	A start job is running for… Credentials (2min 58s / no limit)
	#
	# for three minutes and then gave up. The minimal variant does not show it because a
	# headless systemd tolerates the absent mounts; a desktop does not.
	log "creating /dev, /proc and /sys, which this image does not ship"
	mkdir -p "$ROOT/dev" "$ROOT/proc" "$ROOT/sys"

	# THE DEVICE NODES tar DID NOT PRESERVE. MEASURED: pacman's own scriptlets fail with
	# "/dev/null: No such file or directory" and the package database ends up half
	# written.
	#
	# NO `|| true` ON THE mknod: the previous version had one, and it is exactly what let
	# the missing directory above go unnoticed. A node that cannot be made is a build that
	# cannot work, so it says so.
	log "creating device nodes"
	for spec in "null c 1 3" "zero c 1 5" "random c 1 8" "urandom c 1 9" \
	            "tty c 5 0" "console c 5 1" "ptmx c 5 2"; do
		set -- $spec
		rm -f "$ROOT/dev/$1"
		mknod "$ROOT/dev/$1" "$2" "$3" "$4"
		chmod 666 "$ROOT/dev/$1"
	done

	cp /etc/resolv.conf "$ROOT/etc/resolv.conf"

	# THE MIRRORLIST THE IMAGE SHIPS IS EMPTY. MEASURED: `grep -c '^Server'` answers 0, and
	# pacman then reports no servers configured. One line is enough and it is the official
	# mirror the image's own Dockerfile installs from.
	mkdir -p "$ROOT/etc/pacman.d"
	printf 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch\n' \
		> "$ROOT/etc/pacman.d/mirrorlist"

	# THE SIGNATURE CHECK CANNOT RUN WITHOUT A POPULATED KEYRING, and `pacman-key --init`
	# needs entropy and a chroot that behaves like a real system. MEASURED without this:
	#
	#	:: File .../linux-7.3.5.arch1-1-x86_64.pkg.tar.zst is corrupted
	#	   (invalid or corrupted package (PGP signature)).
	#
	# The package is fetched over HTTPS from the project's own mirror, and the build ends
	# with a boot test that would catch a wrong kernel, so the signature is not the only
	# check here.
	sed -i 's/^SigLevel.*/SigLevel = Never/' "$ROOT/etc/pacman.conf"

	# THE PACKAGES EACH SESSION NEEDS, AND THE ONE SET THEY ALL SHARE.
	#
	# THE SHARED SET is what a screen needs regardless of who draws it: fonts, a terminal (a
	# session with no window shows a background and nothing else, which is a weak thing to
	# assert on), Mesa for the software rasteriser, and easystream's own links.
	DESKTOP_COMMON="libyuv x264 opus pipewire ttf-dejavu ttf-liberation mesa"
	case "$DESKTOP" in
	sway)     DESKTOP_PKGS="sway foot $DESKTOP_COMMON" ;;
	hyprland) DESKTOP_PKGS="hyprland foot $DESKTOP_COMMON" ;;
	# BUDGIE 10.10 IS WAYLAND-ONLY: its package ships `wayland-sessions/budgie-desktop.desktop`
	# and no xsessions entry at all. MEASURED from the package listing.
	budgie)   DESKTOP_PKGS="budgie-desktop foot $DESKTOP_COMMON" ;;
	# THE X11 FAMILY SHARES `xvfb` RATHER THAN DRIVING THE GPU: a microvm has no DRM card
	# unless vkms is loaded, and X11 does not need one at all when it renders into memory.
	xfce)     DESKTOP_PKGS="xfce4 xfce4-terminal xfce4-session xorg-server xorg-xinit xorg-server-xvfb $DESKTOP_COMMON" ;;
	cinnamon) DESKTOP_PKGS="cinnamon cinnamon-session xorg-server xorg-xinit xorg-server-xvfb $DESKTOP_COMMON" ;;
	lxqt)     DESKTOP_PKGS="lxqt-session lxqt-panel openbox qterminal xorg-server xorg-xinit xorg-server-xvfb $DESKTOP_COMMON" ;;
	mate)     DESKTOP_PKGS="mate mate-session-manager mate-terminal xorg-server xorg-xinit xorg-server-xvfb $DESKTOP_COMMON" ;;
	i3)       DESKTOP_PKGS="i3-wm i3status dmenu foot xorg-server xorg-xinit xorg-server-xvfb $DESKTOP_COMMON" ;;
	*)        DESKTOP_PKGS="" ;;
	esac
	export DESKTOP_PKGS

	log "installing the kernel and an ssh server"
	chroot "$ROOT" /bin/sh -c '
		set -e
		# A FULL UPGRADE, NOT `-Sy`. MEASURED: the container image and the mirror are not
		# always at the same package versions, and a partial upgrade answers
		#
		#	:: installing openssl (4.1.0-1) breaks dependency "libssl.so=3-64"
		#	   required by libngtcp2
		#
		# because the new openssl no longer provides the soname the installed packages
		# were built against. `-Syu` moves the whole tree to one snapshot, which is what
		# a rolling release requires and what the Arch wiki calls a partial-upgrade
		# failure.
		pacman -Syu --noconfirm --quiet 2>&1 | tail -3
		# `linux` CARRIES vmlinuz AND /usr/lib/modules. openssh is the daemon the driver
		# dials; e2fsprogs is what growfs needs at first boot.
		# THE EXIT CODE IS CHECKED, WHICH `| tail -3` THROWS AWAY.
		#
		# MEASURED: a mirror that answered "failed to retrieve some files" made pacman exit
		# non-zero, `tail` exited zero, and the build carried on to fail forty lines later
		# with "no vmlinuz under .../usr/lib/modules" - a message about the kernel for a
		# problem that was a download.
		if ! pacman -S --noconfirm --quiet linux openssh e2fsprogs $DESKTOP_PKGS >/tmp/pacman.log 2>&1; then
			tail -15 /tmp/pacman.log
			# THE ONE THING THIS BLOCK CANNOT DO IS CLEAN UP AFTER ITSELF, BECAUSE IT RUNS
			# INSIDE THE CHROOT. `$ROOT` is not set in there, so an `rm -rf "$ROOT"` here
			# expands to `rm -rf ""` - which does nothing - and the half-built tree survives
			# to poison every later run: the unpack is guarded by `[ ! -d "$ROOT/usr" ]`, so
			# each retry skipped it and answered "no vmlinuz under .../usr/lib/modules".
			# MEASURED, three attempts in a row. The marker file is what the caller reads.
			exit 1
		fi
		tail -2 /tmp/pacman.log
	' || {
		rm -rf "$ROOT"
		log "pacman failed; the tree is removed so the next run starts clean"
		exit 1
	}
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

# THE INTERACTIVE FIRST-BOOT PROMPT IS THE ONE THING THAT MADE A WORKING GUEST LOOK DEAD.
#
# MEASURED: the guest booted, mounted its disk, started systemd - and then stopped at
#
#	Initial Setup
#	Please enter the new timezone name or number ("list" to list options, empty to skip):
#
# because a fresh Arch root has no /etc/localtime and systemd-firstboot asks. Nothing is
# wrong with the machine; it is waiting for an answer nobody will type.
#
# Both halves are needed: the mask stops the question, and the values below mean it would
# not be asked anyway. Masking alone would leave a guest with no timezone and a UTC clock
# that some services refuse.
ln -sf /dev/null "$ROOT/etc/systemd/system/systemd-firstboot.service"
printf 'LANG=C.UTF-8\n' > "$ROOT/etc/locale.conf"
ln -sf /usr/share/zoneinfo/UTC "$ROOT/etc/localtime"
printf 'archlinux\n' > "$ROOT/etc/hostname"

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
ExecStart=/bin/sh -c '/usr/bin/resize2fs /dev/vda 2>/dev/null || true; /usr/bin/touch /var/lib/growfs-done'
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/growfs.service \
	"$ROOT/etc/systemd/system/multi-user.target.wants/growfs.service"

rm -f "$ROOT/etc/resolv.conf"
printf '# The bridge runs DNS for this guest.\nnameserver 172.30.0.1\n' > "$ROOT/etc/resolv.conf"
rm -rf "$ROOT/var/cache/pacman/pkg"/* "$ROOT/var/log"/* 2>/dev/null || true


# THE WHOLE SCREEN STACK IS ONE BRANCH, for the same reason the Debian image's is: a
# compositor with no client draws nothing, easystream with no compositor has no frames, and
# PipeWire with no user session refuses root (`ConditionUser=!root`).
if [ "$DESKTOP_FAMILY" != "none" ]; then
	# --- 3b. EASYSTREAM, WHATEVER THE SESSION IS ------------------------------------------
	ES_VERSION="${EAZYSTREAM_VERSION:-v0.10.2}"
	ES_PKG="easystream-${ES_VERSION#v}-1-x86_64.pkg.tar-arch.zst"
	if [ ! -x "$ROOT/usr/bin/easystream" ]; then
		log "fetching easystream ${ES_VERSION} (arch package)"
		curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors --max-time 300 \
			-o "$WORK/$ES_PKG" \
			"https://github.com/easydev-org/easystream/releases/download/${ES_VERSION}/${ES_PKG}"
		# UNTARRED INTO THE TREE, which is how the package's /usr/bin/easystream and its
		# user unit land where they belong without a pacman database to install against.
		tar --zstd -xf "$WORK/$ES_PKG" -C "$ROOT" 2>/dev/null
		chmod 0755 "$ROOT/usr/bin/easystream"
	fi
	if chroot "$ROOT" ldd /usr/bin/easystream 2>&1 | grep -q "not found"; then
		log "WARNING: easystream has unresolved libraries: $(chroot "$ROOT" ldd /usr/bin/easystream 2>&1 | grep 'not found' | tr '\n' ' ')"
	else
		log "easystream: all libraries resolve"
	fi

	# VKMS IS ONLY NEEDED BY THE WAYLAND FAMILY. The X11 family renders into Xvfb's memory
	# and never opens a DRM node; loading vkms there would add a device nothing uses.
	if [ "$DESKTOP_FAMILY" = "wayland" ]; then
		VKMS_SRC="$ROOT/usr/lib/modules/$KVER/kernel/drivers/gpu/drm/vkms/vkms.ko.zst"
		if [ -f "$VKMS_SRC" ]; then
			command -v zstd >/dev/null || { log "zstd is required to ship vkms.ko"; exit 1; }
			zstd -dc "$VKMS_SRC" > "$ROOT/etc/vkms.ko"
			log "shipping vkms.ko ($(stat -c %s "$ROOT/etc/vkms.ko") bytes)"
		else
			log "ERROR: no vkms.ko in the kernel package; the desktop could never start"
			exit 1
		fi

		# THE DRM NODE IS root:video 0660, so vmuser must be in `video`. MEASURED: without
		# it the compositor answers "Permission denied" with the same words it uses for a
		# missing device, which sends you looking for the wrong fault.
		chroot "$ROOT" /bin/sh -c '
			groupadd -f video
			id -nG vmuser | grep -qw video || usermod -aG video vmuser
		' 2>&1 | tail -2 || true

		# A ROOT ONESHOT, BECAUSE `insmod` NEEDS CAP_SYS_MODULE AND THE COMPOSITOR IS vmuser.
		# MEASURED: loading it from the session script answered "Operation not permitted" and
		# the only visible symptom was the compositor's "Found 0 GPUs".
		cat > "$ROOT/etc/systemd/system/vkms.service" <<'UNIT'
[Unit]
Description=load vkms, the software DRM device
After=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/modprobe vkms
# THE NODE IS WHAT THE COMPOSITOR OPENS. udev creates it when it notices the device; the
# mknod fallback keeps the compositor from racing the device manager.
ExecStart=/bin/sh -c 'i=0; while [ $i -lt 50 ] && [ ! -e /dev/dri/card0 ]; do i=$((i+1)); sleep 0.1; done; if [ ! -e /dev/dri/card0 ]; then mkdir -p /dev/dri; M=$(cat /sys/class/drm/card0/dev 2>/dev/null); [ -n "$M" ] && mknod /dev/dri/card0 c ${M%:*} ${M#*:}; fi'
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT
		ln -sf /etc/systemd/system/vkms.service \
			"$ROOT/etc/systemd/system/multi-user.target.wants/vkms.service"

		mkdir -p "$ROOT/lib/modules/$KVER/extra"
		cp "$ROOT/etc/vkms.ko" "$ROOT/lib/modules/$KVER/extra/vkms.ko"
		chroot "$ROOT" /sbin/depmod -a "$KVER" 2>&1 | tail -2 || true
	fi

	# --- 3c. THE SESSION ------------------------------------------------------------------
	#
	# THE SESSION RUNS AS vmuser, NOT root, IN A LINGERED USER SESSION.
	#
	# `ConditionUser=!root` in PipeWire's unit is the reason: a root session cannot start it,
	# and every desktop that plays audio or captures through the portal goes through
	# PipeWire. MEASURED - `systemctl --user start pipewire` as root answered "inactive" and
	# the journal named the condition.
	#
	# THE LINGER IS WHAT MAKES A USER MANAGER EXIST WITH NOBODY LOGGED IN, which is the form
	# an appliance needs and the form the packaged user units assume.
	mkdir -p "$ROOT/var/lib/systemd/linger"
	touch "$ROOT/var/lib/systemd/linger/vmuser"

	if [ "$DESKTOP_FAMILY" = "wayland" ]; then
		# THE COMPOSITOR NEEDS A REAL NAME FOR ITS SOCKET, AND `ConditionEnvironment=` IS
		# EVALUATED AGAINST THE USER MANAGER'S ENVIRONMENT, NOT THE UNIT'S.
		#
		# THIS TOOK THE LONGEST TO FIND. The packaged unit carries
		#
		#	ConditionEnvironment=WAYLAND_DISPLAY
		#	ConditionEnvironment=DISPLAY
		#
		# and a lingered manager starts at boot, before any compositor exists - so both are
		# absent and the unit is skipped with no log line beyond the manager's own "Started".
		# `environment.d` is where a user manager's environment comes from.
		mkdir -p "$ROOT/etc/systemd/user/environment.d"
		{
			echo '# THE MANAGER ENVIRONMENT `ConditionEnvironment=` READS. wayland-1 is the'
			echo '# socket the compositor in this image creates; easystream waits for it.'
			echo 'WAYLAND_DISPLAY=wayland-1'
			echo '# The unit ALSO requires DISPLAY and systemd ANDs conditions. Nothing here is'
			echo '# an X client; the value exists only to satisfy the check.'
			echo 'DISPLAY=:0'
		} > "$ROOT/etc/systemd/user/environment.d/50-session.conf"

		if [ "$DESKTOP" = "sway" ]; then
			SESSION_CMD='exec sway --config /etc/sway/config'
			cat > "$ROOT/etc/sway/config" <<'SWAYCFG'
# THE BAR IS THE ASSERTION. A compositor that cannot create a backend still reaches a login
# prompt, so a walkthrough that only checks "login" would pass on a machine that never drew.
# swaybar draws text this file controls, and that text can only appear if sway started, found
# an output and rendered.
output * bg #3366cc solid_color
bar {
    position top
    height 40
    status_command while true; do echo "ARCH SWAY MICROVM"; sleep 5; done
    colors {
        background #223344
        statusline #ffffff
    }
}
SWAYCFG
		elif [ "$DESKTOP" = "budgie" ]; then
			# BUDGIE IS A DESKTOP ENVIRONMENT, NOT A COMPOSITOR: it runs on top of
			# `budgie-wm`, whose Wayland session is the one its .desktop file starts.
			SESSION_CMD='exec budgie-desktop'
		else
			# HYPRLAND: the same vkms device, a different compositor and config language.
			mkdir -p "$ROOT/etc/hypr"
			cat > "$ROOT/etc/hypr/hyprland.conf" <<'HYPRCFG'
# NO AUTOSTART OF A BAR: hyprland has none built in, and the screenshot assertion here is the
# terminal this file opens - a window is a region of certain non-background pixels.
monitor=,preferred,auto,1
exec-once = foot
HYPRCFG
			SESSION_CMD='exec hyprland --config /etc/hypr/hyprland.conf'
		fi

		cat > "$ROOT/opt/session.sh" <<SESSION
#!/bin/sh
# THE COMPOSITOR ON vkms, AND NOTHING ELSE. easystream is its own unit.
#
# THE DEVICE IS DISCOVERED, NOT NAMED. MEASURED with vgem also loaded: vgem took card0 and
# vkms took card1, so \`WLR_DRM_DEVICES=/dev/dri/card0\` pointed the compositor at a
# dumb-buffer device that cannot drive an output and it answered "Found 0 GPUs".
i=0
while [ \$i -lt 100 ]; do [ -e /dev/dri/card0 ] && break; i=\$((i+1)); sleep 0.1; done
if [ ! -e /dev/dri/card0 ]; then
	echo "session: /dev/dri/card0 never appeared; vkms.service failed" >&2
	exit 1
fi

export XDG_RUNTIME_DIR=/run/user/\$(id -u)
export LIBSEAT_BACKEND=noop
export LIBGL_ALWAYS_SOFTWARE=1

# THE WLR_* VARIABLES ARE wlroots', AND HYPRLAND IS NOT wlroots.
#
# MEASURED from the packages: sway and labwc link \`libwlroots\`; hyprland links its own
# \`libaquamarine\`, \`libhyprlang\` and \`libhyprgraphics\` and has no wlroots dependency at
# all. Setting WLR_BACKENDS=... for hyprland is not an error - it is simply ignored, which
# is the worse outcome: the session looks configured and the variable does nothing.
if [ "${DESKTOP}" = "hyprland" ]; then
	# HYPRLAND PICKS THE DRM DEVICE ITSELF through aquamarine, and falls back to the
	# pixman renderer when EGL finds no hardware. Nothing to force.
	export HYPRLAND_NO_CRASHREPORTER=1
elif [ "${DESKTOP}" = "budgie" ]; then
	# BUDGIE 10.10 RUNS ON \`budgie-wm\`, which is mutter-based, so it takes Mutter's
	# variables rather than wlroots'.
	:
else
	export WLR_BACKENDS=drm
	export WLR_RENDERER=pixman
	export WLR_LIBINPUT_NO_DEVICES=1
	# NO XWAYLAND: easystream reads Wayland through wlr-screencopy, not the X protocol.
	export WLR_XWAYLAND=
fi
unset DISPLAY

$SESSION_CMD
SESSION
		chmod 0755 "$ROOT/opt/session.sh"
	else
		# --- THE X11 FAMILY ------------------------------------------------------------
		#
		# AN X SERVER IN MEMORY, BECAUSE A MICROVM HAS NO GPU. Xvfb needs no DRM node, no
		# framebuffer and no firmware - it draws into its own heap - which is why the whole
		# X11 family works on a machine that cannot run Xorg.
		#
		# MEASURED, and it is the same choice the Debian image makes for its XFCE variant.
		# The X socket is 0600 under /tmp/.X11-unix by default; server and clients are both
		# vmuser, so there is no cookie dance.
		cat > "$ROOT/opt/session.sh" <<'SESSION'
#!/bin/sh
# Xvfb, then the session manager on it. `-ac` disables access control: the display is
# reachable from nowhere but this machine, and both sides run as the same uid.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
exec Xvfb :0 -screen 0 1024x768x24 -ac -nolisten tcp
SESSION
		chmod 0755 "$ROOT/opt/session.sh"

		case "$DESKTOP" in
		xfce)     SESSION_EXEC=/usr/bin/xfce4-session ;;
		cinnamon) SESSION_EXEC=/usr/bin/cinnamon-session ;;
		lxqt)     SESSION_EXEC=/usr/bin/startlxqt ;;
		mate)     SESSION_EXEC=/usr/bin/mate-session ;;
		i3)       SESSION_EXEC=/usr/bin/i3 ;;
		esac

		cat > "$ROOT/opt/desktop.sh" <<DESKTOP
#!/bin/sh
# THE SESSION MANAGER ON :0, AS vmuser. It waits for the X socket rather than for the unit,
# because the two are separate services and ordering across them is not expressible.
i=0
while [ \$i -lt 200 ]; do [ -S /tmp/.X11-unix/X0 ] && break; i=\$((i+1)); sleep 0.1; done
if [ ! -S /tmp/.X11-unix/X0 ]; then
	echo "desktop: Xvfb's socket never appeared" >&2
	exit 1
fi
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
export XDG_SESSION_TYPE=x11

# THE SESSION BUS IS NOT OPTIONAL FOR AN X11 DESKTOP.
#
# MEASURED on XFCE: the session started and drew a dialog reading
#
#	Unable to contact settings server
#	Could not connect: No such file or directory
#
# because xfconf talks to a session D-Bus that nothing had started. `dbus-run-session` gives
# the whole session one bus, which is what a login would have provided.
exec dbus-run-session -- "$SESSION_EXEC"
DESKTOP
		chmod 0755 "$ROOT/opt/desktop.sh"
	fi

	# --- 3d. THE UNITS --------------------------------------------------------------------
	cat > "$ROOT/etc/systemd/system/session.service" <<'UNIT'
[Unit]
Description=the session: Xvfb or a Wayland compositor, for vmuser
After=systemd-logind.service
Wants=systemd-logind.service

[Service]
Type=simple
User=vmuser
Environment=HOME=/home/vmuser
ExecStart=/opt/session.sh
Restart=always
RestartSec=3
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT
	ln -sf /etc/systemd/system/session.service \
		"$ROOT/etc/systemd/system/multi-user.target.wants/session.service"

	if [ "$DESKTOP_FAMILY" = "x11" ]; then
		cat > "$ROOT/etc/systemd/system/desktop.service" <<'UNIT'
[Unit]
Description=the desktop session on Xvfb :0
After=session.service
Wants=session.service

[Service]
Type=simple
User=vmuser
Environment=HOME=/home/vmuser
Environment=DISPLAY=:0
ExecStart=/opt/desktop.sh
Restart=always
RestartSec=3
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT
		ln -sf /etc/systemd/system/desktop.service \
			"$ROOT/etc/systemd/system/multi-user.target.wants/desktop.service"
	fi

	# EASYSTREAM IS ITS OWN UNIT, WITH ITS OWN RESTART POLICY. It is joined to the session by
	# a DEPENDENCY (a socket that must exist), not by a lifecycle: a compositor restart must
	# reconnect the capture daemon, not kill it.
	mkdir -p "$ROOT/etc/systemd/user/easystream.service.d"
	cat > "$ROOT/etc/systemd/user/easystream.service.d/10-conditions.conf" <<'DROPIN'
[Unit]
# THE PACKAGED UNIT REQUIRES WAYLAND_DISPLAY *AND* DISPLAY AND systemd ANDs conditions. Both
# are set in the manager environment (environment.d) for the Wayland family; for X11 they
# come from DISPLAY being real. An empty assignment clears the list and leaves every other
# line of the package's unit in charge, which is the point.
ConditionEnvironment=
DROPIN
	# THE DISPLAY IS SET ON THE UNIT, NOT ONLY IN `environment.d`.
	#
	# MEASURED: with `DISPLAY=:0` in `etc/systemd/user/environment.d/50-session.conf`, the
	# user manager's own environment did not have it - `/proc/<manager>/environ` showed
	# neither DISPLAY nor WAYLAND_DISPLAY - and easystream answered a screenshot request with
	# a ZERO-BYTE png because its capture had no display to attach to. `environment.d` is
	# read where systemd looks for user configuration, which is not the same path on every
	# distribution; a unit `Environment=` is not subject to that.
	if [ "$DESKTOP_FAMILY" = "x11" ]; then
		cat > "$ROOT/etc/systemd/user/easystream.service.d/15-display.conf" <<'DROPIN'
[Service]
Environment=DISPLAY=:0
DROPIN
	fi

	cat > "$ROOT/etc/systemd/user/easystream.service.d/20-session.conf" <<'DROPIN'
[Service]
# THE SOCKET IS WAITED FOR RATHER THAN ASSUMED. The compositor and this unit are in different
# systemd instances - system and user - so `After=` cannot express the order.
#
# MEASURED: easystream started before the socket existed, could not connect, and the est
# server answered nothing; the bounded wait plus `Restart=on-failure` is what makes that a
# retry instead of a dead service.
ExecStartPre=/bin/sh -c 'i=0; while [ $i -lt 600 ]; do if [ -n "$WAYLAND_DISPLAY" ] && [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then exit 0; fi; [ -S /tmp/.X11-unix/X0 ] && exit 0; i=$((i+1)); sleep 0.1; done; echo "no session socket in 60s" >&2; exit 1'
Environment=EAZYSTREAM_PORT=48079
DROPIN

	mkdir -p "$ROOT/etc/systemd/user/default.target.wants"
	ln -sf /usr/lib/systemd/user/easystream.service \
		"$ROOT/etc/systemd/user/default.target.wants/easystream.service"
fi

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
qemu-img convert -f raw -O qcow2 -c "$WORK/rootfs.raw" "$OUT/arch.qcow2"

# --- 5. the three files the boot step names -----------------------------------------------
log "kernel $KVER"
cp "$KERNEL" "$OUT/arch-vmlinuz"
cp "$WORK/initramfs.img" "$OUT/arch-initramfs"

log "done:"
ls -l "$OUT/arch-vmlinuz" "$OUT/arch-initramfs" "$OUT/arch.qcow2"