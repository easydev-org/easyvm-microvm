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
#	0  sway  hyprland  budgie  labwc  wayfire  mangowm
#	   phosh  plasma-mobile  plasma-bigscreen
#	   mate  i3  flashback  deepin
#	   xfce  xfce-wayland  cinnamon  lxqt  lxqt-wayland
#	   qtile  qtile-wayland  enlightenment
#
# cinnamon-wayland IS BACK, BECAUSE virtio-gpu FIXED THE REASON IT WAS DROPPED. It was removed
# for a CAPTURE limit on vkms; the record shows the session was stable there and easystream
# attached and knew the size, but the frame's max pixel was ZERO - the desktop was never
# painted, because muffin is a Mutter fork and wants a render node AND a KMS output on one
# card. MEASURED on virtio-gpu: the full desktop paints (mean 107.4, spread 22.3), and its
# "no video hardware acceleration" notice is the correct state, not a fault. The scanout is
# the evidence, so no capture protocol is needed.
#
# enlightenment-wayland STAYS OUT, AND FOR A DIFFERENT REASON THAT virtio-gpu DOES NOT MOVE.
# It was dropped for a MODE problem (it picked vkms' 4096x2160 and scanned out black), so it
# was re-tested here - and the actual blocker is E's own Evas engine, measured from its log:
#
#	evas-gl-drm ... _evas_outbuf_egl_setup() OpenGL Driver blacklisted:
#	Vendor: Mesa
#	Renderer: llvmpipe (LLVM 23.1.5, 256 bits)
#	evas_gl_new() Evas GL engine not available.
#	KMS: DRM_IOCTL_MODE_CREATE_DUMB failed: Permission denied
#
# E BLACKLISTS THE SOFTWARE RENDERER, exactly as niri refuses it - and with no virgl in this
# QEMU that is the only renderer there is. It then falls back to a KMS dumb buffer path that
# needs DRM master it does not get, and picks 5120x2160 (the largest advertised mode) which is
# why the frame was black. Two of those three are E's own behaviour, not the device's.
# river, weston, kylin, treeland and deepin-wayland were dropped earlier for their own
# measured reasons.
#
# NIRI WAS RE-TESTED ON virtio-gpu AND THE ANSWER IS STILL NO, AND NOW IT IS THE GPU'S FAULT
# RATHER THAN THE CAPTURE PATH'S. It was dropped once for refusing software EGL; the suspicion
# was that this image's old vkms DRM device was the reason. Rebuilt with virtio-gpu over PCIe -
# the guest reports `virtio-gpu: by-path card0 renderD128` and niri's own log confirms it picks
# that device (`using as the render node: "/dev/dri/renderD128"`, `this is the primary node`) -
# and it stops anyway:
#
#	niri::backend::tty: failed to initialize renderer, falling back to primary gpu:
#	                    software EGL renderers are skipped
#	niri::backend::tty: error adding primary node device, display-only devices may not work:
#	                    no allocator available for device
#
# The check is `ensure!(!egl_device.is_software())` in its src/backend/tty.rs, and it is not
# configurable - `strings niri` has no env switch to bypass it. The EGL device really IS
# software because THIS QEMU HAS NO VIRGL: `-device help` lists `virtio-gpu-pci` and
# `virtio-gpu-device` only, with no `virtio-gpu-gl-pci`, so Mesa falls back to llvmpipe for a
# virtio-gpu that offers no 3D. Nothing this image can write changes that: it would take a
# QEMU built with virgl on the host. When that exists, niri is one package line away - the
# session entry is `wayland-sessions/niri.desktop` -> `niri-session`.
#
# THE LIST IS EXHAUSTIVE, TAKEN FROM ARCH'S OWN FILE DATABASE rather than from memory.
# `extra.files.tar.gz` lists every file each package owns, so grepping it for
# `wayland-sessions/.*\.desktop` and `xsessions/.*\.desktop` answers "what sessions does this
# repository ship" with no opinion involved. MEASURED: 28 packages provide a Wayland session
# and 30 provide an X11 one. The first pass at this file used a remembered shortlist and
# MISSED niri, mangowm, qtile, phosh, weston and the two KDE variants entirely.
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
#	X11      xfce, cinnamon,         an X server (Xvfb, in memory),
#	         lxqt, mate, i3           and easystream reads it with XSHM.
#
# KDE AND GNOME CAPTURE BY A THIRD ROUTE: THE SCANOUT. Neither can be read by a capture
# protocol on this image - KWin implements neither wlr-screencopy nor ext-image-copy-capture,
# Mutter's ScreenCast is only offered to a full session-manager session, and both portals stop
# at a consent dialog no headless boot can click. None of that touches the PIXELS: virtio-gpu
# drives a real framebuffer, so qemu's screendump photographs exactly what the compositor
# scanned out. Their walkthroughs measure that (`read the whole screen`), which is why gnome,
# plasma, plasma-mobile and plasma-bigscreen are all variants here.
DESKTOP="${DESKTOP:-0}"

# FIVE DESKTOPS SHIP BOTH KINDS OF SESSION, AND THEY GET ONE NAME EACH PER PROTOCOL.
#
# MEASURED by intersecting the two file-database lists: cinnamon, enlightenment, qtile,
# xfce4-session, and lxqt (whose Wayland session is a SEPARATE package,
# `lxqt-wayland-session`, with `Exec=startlxqtwayland`).
#
# THE BARE NAME IS THE X11 ONE AND `-wayland` IS THE OTHER, which keeps every name that
# already existed working and makes the difference visible in the tag. A desktop that only has
# one protocol has only one name, so nothing is pretending to be a choice it does not have.
case "$DESKTOP" in
0|"")                 DESKTOP_FAMILY=none ;;

# WAYLAND ONLY.
sway|hyprland|budgie|labwc|wayfire|mangowm|phosh|gnome|plasma|plasma-mobile|plasma-bigscreen) DESKTOP_FAMILY=wayland ;;

# X11 ONLY.
mate|i3|flashback) DESKTOP_FAMILY=x11 ;;

# BOTH, AND THE BARE NAME IS THE X11 SESSION.
#
# DEEPIN IS HERE AND IT IS NOT OBVIOUSLY SO. Its X11 entry and its Wayland entry live in
# DIFFERENT PACKAGES, which is why a list built by package name missed the pairing:
#
#	deepin-session  xsessions/deepin.desktop        Exec=/usr/bin/dde-session
#	treeland        wayland-sessions/treeland-user.desktop  Exec=/usr/bin/treeland-user-wrapper
#
# MEASURED from the packages: `dde-session` is the SESSION MANAGER - it is what both entries
# ultimately run - and the COMPOSITOR underneath differs. `deepin-session` depends on
# `deepin-kwin` (Deepin's KWin fork, in its X11 role); `treeland` is Deepin's own Wayland
# compositor and depends on `deepin-session` rather than the other way round.
#
# SO "dde" IS THE DESKTOP AND TREELAND IS ONE OF ITS TWO COMPOSITORS. `deepin-kwin` is the
# other. The `treeland.desktop` that also ships is `Hidden=true` and carries
# `X-DDE-SINGLE-WAYLAND=true` - it is the no-greeter variant, not a second desktop.
xfce|cinnamon|lxqt|qtile|enlightenment|deepin) DESKTOP_FAMILY=x11 ;;
xfce-wayland|lxqt-wayland|qtile-wayland|cinnamon-wayland) DESKTOP_FAMILY=wayland ;;
*)
	echo "DESKTOP=$DESKTOP is not one of: 0 sway hyprland budgie labwc wayfire" >&2
	echo "  mangowm phosh plasma-mobile plasma-bigscreen" >&2
	echo "  mate i3 flashback deepin" >&2
	echo "  dual-stack: xfce xfce-wayland  lxqt lxqt-wayland  qtile qtile-wayland  cinnamon cinnamon-wayland" >&2
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
	# RETRIED, because the registry closes connections mid-body and a build that gives up on
	# the first one can never start. MEASURED: three consecutive runs died inside urllib with
	# RemoteDisconnected and a read timeout, on a network where the layer is fine a minute
	# later. The retry writes to a temporary name so a truncated tar is never seen as complete.
	i=0
	until python3 "$HERE/fetch-image.py" library/archlinux latest "$WORK/rootfs.tar.part" \
		&& mv "$WORK/rootfs.tar.part" "$WORK/rootfs.tar"; do
		i=$((i+1))
		if [ "$i" -ge 5 ]; then
			echo "could not pull archlinux:latest after 5 attempts" >&2
			exit 1
		fi
		rm -f "$WORK/rootfs.tar.part"
		sleep 10
	done
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
	# `xorg-xsetroot` IS HERE FOR THE X11 FAMILY'S BACKGROUND. On Xorg no session manager
	# paints the root window by itself (Xvfb-era guests hid this because nobody could see the
	# screen); without it the desktop is a black field with a panel floating on it. MEASURED on
	# cinnamon and lxqt: mean 6.4 and 9.6, both with their panel drawn and no wallpaper.
	DESKTOP_COMMON="libyuv x264 opus pipewire ttf-dejavu ttf-liberation mesa xorg-xsetroot"
	case "$DESKTOP" in
	sway)     DESKTOP_PKGS="sway foot $DESKTOP_COMMON" ;;
	hyprland) DESKTOP_PKGS="hyprland foot $DESKTOP_COMMON" ;;
	# BUDGIE 10.10 IS WAYLAND-ONLY: its package ships `wayland-sessions/budgie-desktop.desktop`
	# and no xsessions entry at all. MEASURED from the package listing.
	budgie)   DESKTOP_PKGS="budgie-desktop foot $DESKTOP_COMMON" ;;
	# THE THREE BELOW ARE OFFICIAL TOO, and they are the same kind of object as sway - a
	# wlroots compositor with wlr-screencopy built in - so they cost one package each and
	# add real breadth without adding a new capture path.
	labwc)    DESKTOP_PKGS="labwc foot $DESKTOP_COMMON" ;;
	wayfire)  DESKTOP_PKGS="wayfire foot $DESKTOP_COMMON" ;;
	# THE SEVEN BELOW ARE ALSO OFFICIAL `extra` PACKAGES, found by the file-database sweep.
	# xdg-desktop-portal AND ITS wlr BACKEND, BECAUSE MANGO'S SCREENCOPY FORMAT IS NOT READABLE.
	# MEASURED: mango's software-EGL renderer produces AR24/AB24 buffers, easystream answered
	# "invalid buffer format" and "grab screencopy failed", and the est server stayed at the
	# default 1920x1080 with zero-byte frames. The wlr backend of xdg-desktop-portal does its own
	# screen capture and hands easystream a PipeWire stream instead of a raw shm buffer, and it
	# needs NO consent dialog - which is exactly the wall the KDE backend put up.
	mangowm)  DESKTOP_PKGS="mangowm foot grim xdg-desktop-portal xdg-desktop-portal-wlr $DESKTOP_COMMON" ;;
	phosh)    DESKTOP_PKGS="phosh foot $DESKTOP_COMMON" ;;
	# QTILE AND ENLIGHTENMENT SHIP BOTH KINDS OF SESSION; this image takes the Wayland one,
	# because the X11 path is already covered by six other desktops and the Wayland path is
	# the one worth widening.
	qtile)    DESKTOP_PKGS="qtile foot xorg-server xorg-xinit xorg-server-xvfb $DESKTOP_COMMON" ;;
	# BUBBLEWRAP IS WHAT GLYCIN WOULD RUN ITS IMAGE LOADERS IN, and qtile 0.37 loads images
	# through glycin for both its wallpaper and its bar widgets. It is shipped so the loader has
	# somewhere to run; the session ALSO sets GLYCIN_DISABLE_SANDBOX=1, because bwrap cannot set
	# its namespace up in this guest - see that export in the qtile-wayland session branch.
	qtile-wayland)    DESKTOP_PKGS="qtile bubblewrap foot $DESKTOP_COMMON" ;;
	enlightenment) DESKTOP_PKGS="enlightenment foot xorg-server xorg-xinit xorg-server-xvfb $DESKTOP_COMMON" ;;
	# THE KDE VARIANTS ARE SEPARATE PACKAGES FROM plasma-desktop, with their own session files
	# and their own Exec lines. They are not themes: plasma-mobile is a phone shell and
	# plasma-bigscreen is a TV one.
	# THE MAINSTREAM GNOME AND KDE DESKTOPS, from their own session files: gnome.desktop runs
	# /usr/bin/gnome-session; plasma.desktop runs startplasma-wayland. These are the big two the
	# task keeps naming last, verified here the same way as every other Wayland desktop.
	gnome)            DESKTOP_PKGS="gnome gnome-session gdm xdg-desktop-portal xdg-desktop-portal-gnome foot $DESKTOP_COMMON" ;;
	plasma)           DESKTOP_PKGS="plasma-desktop plasma-workspace foot $DESKTOP_COMMON" ;;
	plasma-mobile)    DESKTOP_PKGS="plasma-mobile plasma-workspace foot $DESKTOP_COMMON" ;;
	plasma-bigscreen) DESKTOP_PKGS="plasma-bigscreen plasma-workspace foot $DESKTOP_COMMON" ;;
	# THE THREE CHINESE VENDOR DESKTOPS. MEASURED from their own session files:
	#   kylin    wayland-sessions/kylin-wlcom.desktop  Exec=kylin-wlcom -s ukui-session
	#   treeland wayland-sessions/treeland-user.desktop Exec=/usr/bin/treeland-user-wrapper
	#            and wayland-sessions/treeland.desktop  Exec=/usr/bin/dde-session
	#   deepin   XSESSIONS/deepin.desktop               Exec=/usr/bin/dde-session
	# (kylin and treeland are the Wayland side; deepin-session's own entry is X11.)
	# `deepin-desktop-environment` IS NOT IN THE OFFICIAL REPOS. MEASURED: pacman answered
	# "target not found" for it. What `deepin-session` needs is already in its own dependency
	# list - `deepin-kwin`, `deepin-shell`, `deepin-session-ui`, the dtk6 libraries - so the
	# package is the whole install and adding a meta name that does not exist only breaks it.
	deepin)   DESKTOP_PKGS="deepin-session foot xorg-server xorg-xinit xorg-server-xvfb $DESKTOP_COMMON" ;;
	# THE X11 FAMILY SHARES `xvfb` RATHER THAN DRIVING THE GPU: X11 does not need a DRM card
	# at all when it renders into memory, and this keeps every X11 variant on one code path.
	xfce)     DESKTOP_PKGS="xfce4 xfce4-terminal xfce4-session xorg-server xorg-xinit xorg-server-xvfb $DESKTOP_COMMON" ;;
	# THE SAME DESKTOP ON ITS WAYLAND SESSION. No X server at all - the session file is
	# `xfce-wayland.desktop` and it runs on `labwc` as its compositor, which is why labwc is
	# a dependency here and not a separate variant.
	xfce-wayland)     DESKTOP_PKGS="xfce4 xfce4-terminal xfce4-session labwc $DESKTOP_COMMON" ;;
	# DCONF IS HERE BECAUSE THE WALLPAPER FIX IS A DCONF KEY. See the background note in the
	# session block: cinnamon's schema default points at a .jxl this image cannot decode.
	cinnamon) DESKTOP_PKGS="cinnamon cinnamon-session dconf xorg-server xorg-xinit xorg-server-xvfb $DESKTOP_COMMON" ;;
	# CINNAMON'S WAYLAND SESSION RUNS ON `muffin` AS ITS OWN COMPOSITOR - the same binary that
	# is its X11 window manager, built with the Wayland backend.
	# xdg-desktop-portal-gnome FUNNELS THROUGH org.gnome.Mutter.ScreenCast, WHICH MUFFIN IMPLEMENTS.
	# MEASURED: libmuffin.so carries the Mutter.ScreenCast Session/Stream/Record interface, so the
	# GNOME portal backend can screencast muffin WITHOUT a consent dialog - the wlr backend cannot
	# (muffin has no wlr-screencopy) and grim answered "compositor doesn't support the screen
	# capture protocol". easystream already falls back to the ScreenCast portal.
	# CINNAMON'S WAYLAND SESSION runs on MUFFIN, the Mutter fork that is also its X11 window
	# manager, built with the Wayland backend. It is a Mutter-style compositor, so it wants the
	# same pair as GNOME - a KMS output AND a render node on one device - which is what vkms
	# could not give and virtio-gpu does. See the session branch for the measurement.
	cinnamon-wayland) DESKTOP_PKGS="cinnamon cinnamon-session xdg-desktop-portal xdg-desktop-portal-gnome $DESKTOP_COMMON" ;;
	lxqt)     DESKTOP_PKGS="lxqt-session lxqt-panel openbox qterminal xorg-server xorg-xinit xorg-server-xvfb $DESKTOP_COMMON" ;;
	# LXQT'S WAYLAND SESSION IS A SEPARATE PACKAGE, `lxqt-wayland-session`, whose only job is
	# the `startlxqtwayland` wrapper. MEASURED: `Exec=startlxqtwayland`, and it needs a
	# compositor of its own - labwc, the same one XFCE's Wayland session uses.
	lxqt-wayland)     DESKTOP_PKGS="lxqt-session lxqt-panel lxqt-wayland-session qterminal labwc $DESKTOP_COMMON" ;;
	mate)     DESKTOP_PKGS="mate mate-session-manager mate-terminal xorg-server xorg-xinit xorg-server-xvfb $DESKTOP_COMMON" ;;
	i3)       DESKTOP_PKGS="i3-wm i3status dmenu foot xorg-server xorg-xinit xorg-server-xvfb $DESKTOP_COMMON" ;;
	# GNOME FLASHBACK IS GNOME'S OWN X11 SESSION, NOT AN OLD FORK: MEASURED, its package is
	# 3.58.0 - the same generation as GNOME 51 - and it ships exactly one session file,
	# `xsessions/gnome-flashback-metacity.desktop`, with `Exec=/usr/lib/gnome-flashback-metacity`.
	# It is the ONLY way to run a GNOME desktop on X11 today, because the main GNOME session
	# dropped X11 in 45.
	flashback) DESKTOP_PKGS="gnome-flashback gnome-panel gnome-session gnome-settings-daemon metacity nautilus xorg-server xorg-xinit xorg-server-xvfb $DESKTOP_COMMON" ;;
	*)        DESKTOP_PKGS="" ;;
	esac
	export DESKTOP_PKGS

	log "installing the kernel and an ssh server"
	# PACMAN GOES THROUGH A PROXY IF THE BUILD HAS ONE, BECAUSE chroot DOES NOT INHERIT IT.
	#
	# MEASURED: `chroot` starts a fresh environment and drops https_proxy, so when a proxy IS
	# configured the pacman inside reached the mirror directly and crawled. The proxy is written
	# to a file the chroot sources - but ONLY when the build shell actually has one. MEASURED the
	# other way: hard-coding the lab's mihomo host made EVERY CI job fail with
	# "Could not resolve proxy: mihomo.develop.svc.cluster.local", because that host exists only
	# in the lab, not on a GitHub runner. With no outer proxy, this file is empty and pacman
	# connects directly, which is what CI needs.
	if [ -n "${https_proxy:-}" ]; then
		mkdir -p "$ROOT/tmp"
		printf 'export https_proxy=%s\nexport http_proxy=%s\nexport no_proxy=127.0.0.1,localhost,::1\n' \
			"$https_proxy" "$https_proxy" > "$ROOT/tmp/proxy.env"
	else
		: > "$ROOT/tmp/proxy.env"
	fi
	chroot "$ROOT" /bin/sh -c '
		set -e
		[ -s /tmp/proxy.env ] && . /tmp/proxy.env || true
		# ONE DOWNLOAD AT A TIME, BECAUSE THE PARALLEL DOWNLOADER STALLS HERE.
		# MEASURED: a single package from the mirror over the proxy runs at ~23 MB/s, but
		# the default parallel downloads of several large files (linux, webkit2gtk,
		# ghostscript, perl ...) crawl at a few MB/min - the concurrent connections are what
		# throttles. Serialising them makes the big cinnamon/webkit dependency set finish.
		sed -i "s/^#\? *ParallelDownloads.*/ParallelDownloads = 1/" /etc/pacman.conf
		grep -q "^ParallelDownloads" /etc/pacman.conf || echo "ParallelDownloads = 1" >> /etc/pacman.conf
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
		# NO PIPE TO TAIL: MEASURED, the Arch container image has no coreutils at this point,
		# and the shell answered "tail: command not found" - so the pipe silenced the
		# updater output AND its status. `--quiet` already keeps it quiet.
		# (No apostrophes in this block: it is inside a single-quoted chroot command.)
		pacman -Syu --noconfirm --quiet
		# `linux` CARRIES vmlinuz AND /usr/lib/modules. openssh is the daemon the driver
		# dials; e2fsprogs is what growfs needs at first boot.
		# THE EXIT CODE IS CHECKED, WHICH `| tail -3` THROWS AWAY.
		#
		# MEASURED: a mirror that answered "failed to retrieve some files" made pacman exit
		# non-zero, `tail` exited zero, and the build carried on to fail forty lines later
		# with "no vmlinuz under .../usr/lib/modules" - a message about the kernel for a
		# problem that was a download.
		# THE TEST IS "DID THE KERNEL ARRIVE", NOT "DID PACMAN EXIT ZERO".
		#
		# MEASURED, and it cost six builds: `systemd-tmpfiles` needs /proc and the journal
		# catalog hook wants a file this image does not ship, so pacman prints
		# "error: command failed to execute correctly" twice and STILL INSTALLS EVERYTHING.
		# An exit-code check refused six good builds in a row - the opposite of the bug it was
		# written to catch, which was a download failure that left no kernel at all.
		i=0
		until pacman -S --noconfirm --quiet linux openssh e2fsprogs $DESKTOP_PKGS >/tmp/pacman.log 2>&1; do
			i=$((i+1))
			[ "$i" -ge 5 ] && break
			sleep 5
		done
		if ! ls /usr/lib/modules/*/vmlinuz >/dev/null 2>&1; then
			# `cat`, not `tail`: tail does not exist in this tree yet.
			cat /tmp/pacman.log
			# THE ONE THING THIS BLOCK CANNOT DO IS CLEAN UP AFTER ITSELF, BECAUSE IT RUNS
			# INSIDE THE CHROOT. `$ROOT` is not set in there, so an `rm -rf "$ROOT"` here
			# expands to `rm -rf ""` - which does nothing - and the half-built tree survives
			# to poison every later run: the unpack is guarded by `[ ! -d "$ROOT/usr" ]`.
			exit 1
		fi
		# WARNINGS ARE RECORDED, NOT IGNORED, because the next person should know which two
		# hooks always fail in a chroot and which would be new.
		grep -E "^(error|warning)" /tmp/pacman.log >&2 || true
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

	# --- 3b-ii. THE KDE PORTAL'S CONSENT DIALOG, ANSWERED IN ADVANCE --------------------
	#
	# THE PROBLEM. KWin implements neither wlr-screencopy nor ext-image-copy-capture, so a
	# Plasma variant can only be captured through xdg-desktop-portal-kde's ScreenCast - and
	# that backend's Start() ends in
	#
	#	portal: SelectDevices ok
	#	portal: no Response for /org/freedesktop/portal/desktop/request/1_51/est1
	#
	# because it waits for a human to click a consent dialog. A headless boot has nobody.
	#
	# THE ANSWER IS THE BACKEND'S OWN MECHANISM, not a workaround invented here. MEASURED
	# from xdg-desktop-portal-kde/src/remotedesktop.cpp, which documents
	#
	#	// Mega-authorization is a permission system specific to the KDE portal
	#	// implementation. A mega-authorized application is one that has been granted
	#	// permissions to access all (remote desktop) features **without** any further user
	#	// interaction. Particularly useful for headless setups and when the user is not
	#	// physically at the machine.
	#
	# and whose Start() is
	#
	#	if (restored || isAppMegaAuthorized(app_id)) { continueStart(session); }  // no dialog
	#	else if (!isAppMegaAuthorized(app_id))       { new RemoteDesktopDialog(...); }
	#
	# So one row in the permission store's `kde-authorized` / `remote-desktop` table, keyed
	# by the EMPTY app id (which the source says means "a host application" - a non-flatpak
	# binary, which easystream is), makes Start answer with no dialog at all.
	#
	# MEASURED end to end on Plasma Wayland over virtio-gpu, with this row present:
	#
	#	portal: SelectDevices ok
	#	portal: stream state=streaming error=(none)
	#	portal: negotiated 1024x768 format=8
	#	portal: frame #1 1024x768 stride=4096 size=3145728
	#
	# THE WRITE RUNS AT BOOT, NOT BUILD TIME, because the permission store is a service on
	# the session bus and keeps its table in the user's runtime state. A unit does it as
	# vmuser, before the session's capture unit asks for a stream.
	if [ "$DESKTOP_FAMILY" = "wayland" ]; then
		cat > "$ROOT/opt/kde-mega-auth.sh" <<'KMEGA'
#!/bin/sh
# Grant this desktop's portal permission to capture without a consent dialog, using the
# backend's own mega-authorisation table. See the long note in arch-rootfs.sh.
set -u
TABLE=kde-authorized
ID=remote-desktop
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

# The portal's stores come up with the session bus; wait rather than fail.
i=0
while [ $i -lt 300 ]; do
	busctl --user status org.freedesktop.impl.portal.PermissionStore >/dev/null 2>&1 && break
	i=$((i + 1)); sleep 0.1
done
if ! busctl --user status org.freedesktop.impl.portal.PermissionStore >/dev/null 2>&1; then
	# NOT AN ERROR ON A NON-KDE SESSION: GNOME's backend has no such table and never
	# consults one, so there is nothing to write and nothing to complain about.
	echo "kde-mega-auth: no KDE permission store on this session; nothing to grant" >&2
	exit 0
fi

gdbus call --session \
	--dest org.freedesktop.impl.portal.PermissionStore \
	--object-path /org/freedesktop/impl/portal/PermissionStore \
	--method org.freedesktop.impl.portal.PermissionStore.Set \
	"$TABLE" true "$ID" '{"": ["yes"]}' '<@v <@ay []>>' >/dev/null 2>&1

if gdbus call --session \
	--dest org.freedesktop.impl.portal.PermissionStore \
	--object-path /org/freedesktop/impl/portal/PermissionStore \
	--method org.freedesktop.impl.portal.PermissionStore.Lookup \
	"$TABLE" "$ID" 2>/dev/null | grep -q "'yes'"; then
	echo "kde-mega-auth: $TABLE/$ID grants the empty app id -> Start will not ask"
else
	echo "kde-mega-auth: FAILED to write $TABLE/$ID" >&2
fi
KMEGA
		chmod 0755 "$ROOT/opt/kde-mega-auth.sh"
	fi

	# --- 3b. THE GPU ------------------------------------------------------------------
	#
	# VIRTIO-GPU, NOT VKMS. The display device is the one QEMU attaches as virtio-gpu-pci,
	# and it is BOTH the KMS output (card0-Virtual-1) and the render node (renderD128).
	#
	# MEASURED: vkms never had a render node - its driver_features leaves out DRIVER_RENDER,
	# so the kernel makes card0 but no renderD* - and Mutter needs an EGL device that carries
	# EGL_EXT_device_drm_render_node. vgem supplied renderD128 but no KMS output, and Mutter
	# ignores a non-primary GPU, so GDM answered "No GPUs found" and Xorg answered "No devices
	# detected". virtio-gpu is a real driver with DRIVER_MODESET|DRIVER_GEM|DRIVER_RENDER, so
	# one device satisfies both halves.
	#
	# MEASURED: the device only binds over PCIe. On microvm's virtio-mmio bus the Linux guest
	# claims virtio-blk but leaves virtio-gpu unprobed; `-M microvm,pcie=on` with
	# `-device virtio-gpu-pci` produces
	#   [drm] Initialized virtio_gpu 0.1.0 for 0000:00:02.0 on minor 0
	# and /sys/class/drm lists card0, card0-Virtual-1 and renderD128.
	#
	# EXACTLY TWO NODES, AND THAT IS THE WHOLE OF IT: one card0 that carries BOTH the scanout and
	# the render side, and renderD128 as its render node. There is no separate card1, no "gpu0"
	# and no second device - and none of the desktops here want one. All twenty-one variants were
	# checked from CI's own console logs and every Wayland one reports the same line
	#
	#	virtio-gpu: by-path card0 renderD128
	#
	# while every X11 one boots `without a display` and reports nothing, because it renders into
	# Xvfb's memory and never opens a DRM node.
	#
	# WHAT THE PAIR IS AND IS NOT ENOUGH FOR, MEASURED. Enough for: Mutter (GDM + gnome-shell),
	# KWin (all three Plasma shells), wlroots' EGL path (sway, labwc, wayfire, hyprland, budgie,
	# mangowm, phosh, xfce-wayland, lxqt-wayland, qtile-wayland) and every X11 session. Not
	# enough for niri, and NOT because the nodes are wrong: its EGL device is classified SOFTWARE
	# because this QEMU has no virgl (`-device help` lists only virtio-gpu-pci/-device, no
	# virtio-gpu-gl-pci), and niri refuses a software EGL device outright. See the note beside
	# the removed niri entry above.
	if [ "$DESKTOP_FAMILY" = "wayland" ] || [ "$DESKTOP_FAMILY" = "x11" ]; then
		VG_SRC="$ROOT/usr/lib/modules/$KVER/kernel/drivers/gpu/drm/virtio/virtio-gpu.ko.zst"
		if [ ! -f "$VG_SRC" ]; then
			log "ERROR: no virtio-gpu module in the kernel package; the desktop could never start"
			exit 1
		fi

		# THE DRM NODE IS root:video 0660, so vmuser must be in `video` to open card0, and in
		# `render` to open renderD128. MEASURED: without `video` the compositor answers
		# "Permission denied" with the same words it uses for a missing device.
		chroot "$ROOT" /bin/sh -c '
			groupadd -f video
			groupadd -f render
			id -nG vmuser | grep -qw video || usermod -aG video vmuser
			id -nG vmuser | grep -qw render || usermod -aG render vmuser
		' 2>&1 | tail -2 || true

		# GETTY MUST NOT SIT ON THE VT XORG TAKES, AND THAT IS A RACE RATHER THAN A RULE.
		#
		# MEASURED on the mate variant, and it is the one X11 desktop that lost it: systemd's
		# autovt@ starts `Getty on tty1` as the graphical target comes up, and when it wins the
		# race Xorg answers
		#
		#	Fatal server error:
		#	(EE) xf86OpenConsole: Switching VT failed
		#
		# and exits - repeatedly, so the console shows a black field with a session marker and
		# nothing else. The other X11 variants happened to start Xorg first, which is why this
		# looked like a mate-specific fault.
		#
		# A guest whose desktop OWNS tty1 has no reason to run a login prompt on it: the serial
		# console on ttyS0 is where a person logs in, and it is untouched by this.
		# MASKED, NOT MERELY DISABLED: `ln -sf /dev/null` is systemd's own way of saying a unit
		# does not exist here, and it beats both `systemctl disable` (which only removes a want
		# link) and a Condition= (which still lets something else pull it in).
		rm -f "$ROOT/etc/systemd/system/getty.target.wants/getty@tty1.service"
		ln -sf /dev/null "$ROOT/etc/systemd/system/getty@tty1.service"
		ln -sf /dev/null "$ROOT/etc/systemd/system/autovt@tty1.service"

		# XORG NEEDS THE TTY GROUP, and only the X11 family runs Xorg. MEASURED: without it
		# `xf86OpenConsole: Cannot open virtual console 5 (Permission denied)` and the server
		# exits, because /dev/tty1 is root:tty 0620.
		if [ "$DESKTOP_FAMILY" = "x11" ]; then
			chroot "$ROOT" /bin/sh -c '
				groupadd -f tty
				id -nG vmuser | grep -qw tty || usermod -aG tty vmuser
			' 2>&1 | tail -1 || true
		fi

		# A ROOT ONESHOT: the compositor is vmuser and has no CAP_SYS_MODULE, and udev may not
		# have made the nodes yet when the session starts. The mknod fallback removes that race.
		cat > "$ROOT/etc/systemd/system/gpu.service" <<'UNIT'
[Unit]
Description=load virtio-gpu, the KMS output and render node
After=systemd-modules-load.service
Before=display-manager.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/modprobe virtio-gpu
ExecStart=/bin/sh -c 'i=0; while [ $i -lt 100 ] && [ ! -e /sys/class/drm/renderD128 ]; do i=$((i+1)); sleep 0.1; done; for n in card0 renderD128; do [ -e /dev/dri/$n ] && continue; M=$(cat /sys/class/drm/$n/dev 2>/dev/null); [ -n "$M" ] && { mkdir -p /dev/dri; mknod /dev/dri/$n c ${M%:*} ${M#*:}; }; done; chgrp video /dev/dri/card0 2>/dev/null; chmod 660 /dev/dri/card0 2>/dev/null; chgrp render /dev/dri/renderD128 2>/dev/null; chmod 660 /dev/dri/renderD128 2>/dev/null; echo "virtio-gpu: $(ls /dev/dri 2>/dev/null | tr "\n" " ")"; true'
StandardOutput=journal+console
StandardError=journal+console
[Install]
WantedBy=multi-user.target
UNIT
		ln -sf /etc/systemd/system/gpu.service \
			"$ROOT/etc/systemd/system/multi-user.target.wants/gpu.service"

		# udev alone is not enough on this kernel: MEASURED, /dev/dri stayed empty until the
		# unit created the nodes by hand from /sys/class/drm/*/dev.
		log "virtio-gpu: shipped for a real render node + output"
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
		# THE MANAGER ENVIRONMENT IS SET WHEN THE SOCKET IS KNOWN, NOT HERE.
		#
		# A COMPOSITOR DOES NOT ALWAYS GET THE NAME wayland-1. wlroots asks libwayland for the
		# first free name, which is wayland-0 on a clean boot: MEASURED, sway and labwc on the
		# same image produced DIFFERENT names, and a fixed value broke whichever one differed.
		# The name is discovered from the filesystem in session.sh and pushed into the manager
		# with `systemctl --user set-environment` before the capture unit starts.

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
		elif [ "$DESKTOP" = "labwc" ]; then
			# LABWC HAS NO WALLPAPER AND NO BAR OF ITS OWN, so a bare session captures a BLACK
			# FRAME WITH A CURSOR - a real render, but nothing in it proves which compositor
			# made it. MEASURED: exactly that, 3146804 bytes of black.
			#
			# THE EVIDENCE IS A CLIENT, STARTED THROUGH A SCRIPT RATHER THAN A QUOTED STRING.
			# MEASURED with `-s "foot -T ... -e sh -c \"...\""`: labwc printed
			# "slave.c:554: LABWC: failed to execute: No such file or directory" because its
			# startup command is split and exec'd, not handed to a shell - the quotes were
			# treated as part of the program name. A file has no quoting to get wrong.
			SESSION_CMD='exec labwc -s /opt/startup-client.sh'
			cat > "$ROOT/opt/startup-client.sh" <<'STARTUP'
#!/bin/sh
exec foot -T "ARCH LABWC MICROVM" -e sh -c 'echo ARCH LABWC MICROVM; echo compositor: labwc; echo socket: $WAYLAND_DISPLAY; sleep 3600'
STARTUP
			chmod 0755 "$ROOT/opt/startup-client.sh"
		elif [ "$DESKTOP" = "wayfire" ]; then
			# WAYFIRE DOES HAVE A PANEL AND A BACKGROUND, but its default config opens none of
			# them, so a bare start is black too. One client is enough evidence, and wayfire's
			# own `[autostart]` section is where it belongs.
			# THE CONFIG PATH IS MEASURED, NOT GUESSED. wayfire's log said
			# "Using config file: /home/vmuser/.config/wayfire.ini", and it does NOT read
			# /etc/xdg/wayfire/wayfire.ini - an autostart written there would never have run.
			mkdir -p "$ROOT/home/vmuser/.config"
			cat > "$ROOT/home/vmuser/.config/wayfire.ini" <<'WAYFIRE'
[autostart]
term = foot -T "ARCH WAYFIRE MICROVM" -e sh -c 'echo ARCH WAYFIRE MICROVM; echo compositor: wayfire; echo socket: $WAYLAND_DISPLAY; sleep 3600'
WAYFIRE
			chown -R 1000:1000 "$ROOT/home/vmuser" 2>/dev/null || true
			SESSION_CMD='exec wayfire'
		elif [ "$DESKTOP" = "mangowm" ]; then
			# VERIFIED - WITH grim, NOT easystream. MEASURED: mangowm is a wlroots compositor, so
			# it DOES implement zwlr_screencopy; grim against its socket returned a 1024x768 png
			# with 786432 of 786432 pixels non-black (max 255) - the full desktop, the foot window
			# titled "ARCH MANGOWM MICROVM", and its focus border. easystream against the SAME
			# socket answers "invalid buffer format" / "grab screencopy failed" and serves an
			# all-zero frame, so easystream's shm/format handling is what is broken here, not the
			# compositor. grim is therefore the capture for this desktop (it is in official
			# `extra`), and a grim-probe unit dumps its png to the console for the harness.
			#
			# `mango -s <command>` IS ITS STARTUP FLAG; MEASURED from its own `-h`:
			# "-s <command>   Execute startup command". The script is used rather than a quoted
			# string for the same reason as labwc: exec'd arguments, not a shell.
			SESSION_CMD='exec mango -s /opt/startup-client.sh'
			cat > "$ROOT/opt/startup-client.sh" <<'STARTUP'
#!/bin/sh
exec foot -T "ARCH MANGOWM MICROVM" -e sh -c 'echo ARCH MANGOWM MICROVM; echo compositor: mangowm; echo socket: $WAYLAND_DISPLAY; sleep 3600'
STARTUP
			chmod 0755 "$ROOT/opt/startup-client.sh"
			# THE WLR PORTAL BACKEND IS STARTED EXPLICITLY, because easystream asks the portal only
			# once per process and systemd's on-demand start races that first ask.
			cat > "$ROOT/opt/portal-up.sh" <<'PUP'
#!/bin/sh
systemctl --user start pipewire pipewire-pulse wireplumber 2>/dev/null || true
systemctl --user start xdg-desktop-portal 2>/dev/null || true
systemctl --user start xdg-desktop-portal-wlr 2>/dev/null || true
PUP
			chmod 0755 "$ROOT/opt/portal-up.sh"
		elif [ "$DESKTOP" = "phosh" ]; then
			SESSION_CMD='exec phosh-session'
		elif [ "$DESKTOP" = "xfce-wayland" ]; then
			# THE SESSION FILE'S OWN LINE: `Exec=startxfce4 --wayland`. labwc is the compositor
			# that `--wayland` drives, which is why it is in this variant's package list.
			SESSION_CMD='exec startxfce4 --wayland'
		elif [ "$DESKTOP" = "cinnamon-wayland" ]; then
			# `Exec=cinnamon-session-cinnamon --wayland`, from the session file.
			#
			# IT RAN END TO END ON vkms AND STILL DREW NOTHING, AND THAT IS WHY virtio-gpu FIXED
			# IT. MEASURED on vkms: the session was stable (the marker printed once, no restart
			# loop) and easystream attached and reported "encoder opened 1024x768", but the
			# frame's max pixel was 0 - not a capture failure, a DESKTOP THAT WAS NEVER PAINTED.
			# muffin is a Mutter fork, so it carries GDM's requirement: an EGL device with a
			# render node AND a KMS output on the same card. vkms had no render node, vgem's
			# render node had no output, and Mutter-style code ignores a non-primary GPU.
			#
			# MEASURED on virtio-gpu: the FULL Cinnamon desktop - wallpaper, bottom panel, clock -
			# at mean brightness 107.4, spread 22.3. Cinnamon also shows its "running without
			# video hardware acceleration" notice, which is the CORRECT state here: there is no
			# virgl, so the renderer is llvmpipe. It proves muffin started and probed the GPU.
			#
			# nemo IS THE BACKGROUND PAINTER and cinnamon-session lists it as a RequiredComponent,
			# so two things were in tension on vkms: without a shim "nemo-autostart respawning too
			# quickly" tore the session down; with one the session survived but nothing drew.
			# nemo-desktop is therefore started as an ORDINARY PROCESS by the wrapper, and the
			# session's required list is cut to the compositor alone.
			if [ -f "$ROOT/usr/share/cinnamon-session/sessions/cinnamon-wayland.session" ]; then
				sed -i "s/^RequiredComponents=.*/RequiredComponents=cinnamon-wayland;/" \
					"$ROOT/usr/share/cinnamon-session/sessions/cinnamon-wayland.session"
			fi
			cat > "$ROOT/opt/cinn-nemo.sh" <<'NEMO'
#!/bin/sh
i=0
while [ $i -lt 200 ]; do
	[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && break
	i=$((i+1)); sleep 0.1
done
sleep 2
exec /usr/bin/nemo-desktop
NEMO
			chmod 0755 "$ROOT/opt/cinn-nemo.sh"
			cat > "$ROOT/opt/cinn-session.sh" <<'CSESS'
#!/bin/sh
/opt/cinn-nemo.sh &
exec /usr/bin/cinnamon-session-cinnamon --wayland
CSESS
			chmod 0755 "$ROOT/opt/cinn-session.sh"
			SESSION_CMD='exec /opt/cinn-session.sh'
		elif [ "$DESKTOP" = "lxqt-wayland" ]; then
			# `Exec=startlxqtwayland`, provided by the separate `lxqt-wayland-session` package.
			SESSION_CMD='exec startlxqtwayland'
		elif [ "$DESKTOP" = "qtile-wayland" ]; then
			# `qtile start` CHECKS WAYLAND_DISPLAY ITSELF and starts the Wayland backend when it
			# is set - the session file for both is the same command.
			#
			# GLYCIN GETS ITS SANDBOX TURNED OFF, BECAUSE BUBBLEWRAP CANNOT WORK IN THIS GUEST.
			#
			# MEASURED on virtio-gpu: a bare `qtile start` writes its own default config, that
			# config sets `wallpaper=logo` and the CurrentLayout widget icon, and loading EITHER
			# goes through glycin, which spawns its loader inside `bwrap --unshare-all`. bwrap
			# there fails, and qtile answers
			#
			#	cairocffi.pixbuf.ImageLoadingError: Pixbuf error: Loader process exited early
			#	with status '1' Command: "bwrap" "--unshare-all" ... "--seccomp" "35" ...
			#
			# then exits 1 about four seconds after the session marker - forever, with nothing
			# else on the console. Installing bubblewrap is not enough: the loader still fails
			# inside the namespace on this guest (MEASURED, bwrap present and the loader still
			# exiting 1), because the seccomp/unshare setup needs privileges a microvm guest
			# without a real seat does not have.
			#
			# GLYCIN DOCUMENTS ITS OWN ESCAPE HATCH FOR EXACTLY THIS, and this image is a
			# single-user appliance whose images all come from its own root filesystem:
			#
			#	GLYCIN_DISABLE_SANDBOX=1   ("Bubblewrap (bwrap) doesn't work in the environment")
			#
			# MEASURED with it: no ImageLoadingError, no crash, and the session stayed up for the
			# whole observation window. The sandbox protects against a MALICIOUS image file; the
			# only files here are the ones this build installed. The export itself lives in
			# session.sh, because THIS block only chooses the command - its environment does not
			# reach the session (MEASURED: put here first, and the emitted script had no export).
			#
			# AND THE CONFIG IS WRITTEN, BECAUSE THE DEFAULT ONE STILL CRASHES EVEN WITHOUT THE
			# SANDBOX. MEASURED: with the sandbox off and qtile's own generated config, the
			# CurrentLayout widget reads PNG arrows out of the package and STILL raises
			# "AttributeError: Img has no attribute _default_size" on this Pillow/cairocffi
			# combination - a bug in the widget, not in this image. That is a crash at bar
			# creation, so the whole session dies. A config that names only widgets which draw
			# from text - GroupBox, the title, the clock - starts and stays up; MEASURED, that
			# bar renders "ARCH QTILE-WAYLAND MICROVM" at the bottom right.
			mkdir -p "$ROOT/home/vmuser/.config/qtile"
			cat > "$ROOT/home/vmuser/.config/qtile/config.py" <<'QTILECFG'
# THE CONTENT OF THE BAR IS THE PROOF: the title text is drawn by qtile itself, so a capture
# that shows it means the compositor started, found the output and rendered. CurrentLayout is
# deliberately absent - it loads PNG arrows and crashes on this image's Pillow/cairocffi.
from libqtile import bar, layout, widget
from libqtile.config import Screen

screens = [
    Screen(
        bottom=bar.Bar(
            [
                widget.GroupBox(),
                widget.WindowName(),
                widget.TextBox("ARCH QTILE-WAYLAND MICROVM"),
                widget.Clock(format="%Y-%m-%d %H:%M"),
            ],
            24,
        ),
    ),
]
layouts = [layout.Columns(border_focus="#d75f5f"), layout.Max()]
QTILECFG
			chown -R 1000:1000 "$ROOT/home/vmuser" 2>/dev/null || true
			SESSION_CMD='exec qtile start'
		elif [ "$DESKTOP" = "gnome" ]; then
			# THE FULL STACK: GDM AS THE DISPLAY MANAGER, NOT A BARE gnome-shell.
			#
			# GNU GNOME's session is assembled by a DISPLAY MANAGER. A bare `gnome-shell`, or a
			# `gnome-session` launched outside one, is NOT a full session: xdg-desktop-portal-gnome
			# answers "Non-compatible display server, exposing settings only." and never provides the
			# ScreenCast interface, so easystream has no portal to capture through and the frame is
			# black. MEASURED. GDM starts the greeter and then the real gnome-session, which registers
			# org.gnome.Shell with the session manager - the condition the portal needs.
			#
			# GDM'S GL NEEDS A RENDER NODE AND A KMS OUTPUT ON THE SAME GPU, AND virtio-gpu IS
			# THAT GPU. MEASURED on the PCIe transport:
			#	[drm] Initialized virtio_gpu 0.1.0 for 0000:00:02.0 on minor 0
			#	/sys/class/drm: card0 card0-Virtual-1 renderD128
			# so Mutter's MetaRenderDeviceGbm finds an EGL device carrying
			# EGL_EXT_device_drm_render_node while the same card0 drives the scanout. (vkms had
			# card0 with no render node at all; vgem added renderD128 but no output, and Mutter
			# ignores a non-primary GPU - that was the old "No GPUs found" ceiling.)
			#
			# AUTOLOGIN, so the machine reaches the desktop with no one to type - the same appliance
			# shape the console session already uses.
			mkdir -p "$ROOT/etc/gdm"
			cat > "$ROOT/etc/gdm/custom.conf" <<'GDMCONF'
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=vmuser
WaylandEnable=true
GDMCONF
			# GDM IS THE DISPLAY MANAGER: an Alias to display-manager.service, so `graphical.target`
			# pulls it in and it owns tty1.
			ln -sf /usr/lib/systemd/system/gdm.service \
				"$ROOT/etc/systemd/system/display-manager.service"
			# THE USER MANAGER STILL NEEDS XDG_SESSION_TYPE for org.gnome.Shell@.service's assert.
			mkdir -p "$ROOT/etc/systemd/user/environment.d"
			cat > "$ROOT/etc/systemd/user/environment.d/50-gnome.conf" <<'GENV'
XDG_SESSION_TYPE=wayland
XDG_CURRENT_DESKTOP=GNOME
XDG_SESSION_DESKTOP=gnome
GENV
			# THE SESSION SERVICE IS NOT USED FOR GNOME: GDM OWNS THE SESSION. Its unit must not also
			# start a compositor on the same tty, so the desktop family is marked so the generic
			# session.service is skipped for this desktop (handled where the units are written).
			DESKTOP_SKIP_SESSION_SERVICE=1
			# session.sh is still WRITTEN (the builder expects a command) but never RUN, because
			# session.service is skipped for this desktop. A no-op keeps that builder happy without
			# launching a second compositor on tty1 next to GDM.
			SESSION_CMD='exec sleep infinity'

		elif [ "$DESKTOP" = "plasma" ]; then
			# `plasma.desktop`: Exec=/usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasma-wayland
			# - the mainstream KDE Plasma Wayland session, from its own session file.
			#
			# THE SESSION IS STABLE (ARCH-SESSION-STARTING once, kwin_wayland on wayland-1). WHAT
			# DOES NOT WORK IS READING IT THROUGH A PROTOCOL: KWin implements neither
			# zwlr_screencopy nor ext-image-copy-capture, and KDE's ScreenCast portal stops at a
			# consent dialog a headless boot cannot click (see the long note under plasma-mobile).
			#
			# THE PIXELS THEMSELVES NEED NO PROTOCOL. virtio-gpu drives a real framebuffer, so
			# qemu's screendump photographs exactly what KWin scanned out - the walkthrough's
			# `read the whole screen as "screen"` measures that. MEASURED on this image: the full
			# Plasma desktop (wallpaper, bottom panel, clock, tray) at 1024x768, mean brightness
			# 128.6 with a mean deviation of 37.0. That is the evidence this variant ships, and it
			# is the same one the GNOME variant uses.
			# DPMS MUST BE OFF, OR THE CAPTURE IS A BLACK FRAME.
			#
			# MEASURED on this image: Plasma's power management turns the output off after its
			# idle timeout, /sys/class/drm/card0-Virtual-1/dpms reads "Off", and every portal
			# frame is then uniformly black - the stream itself is healthy ("stream
			# state=streaming", "frame #1 1024x768"), which is what makes this easy to
			# misdiagnose as a portal failure. With DPMS forced on the same capture jumps from
			# ~3 KB frames to 260 KB.
			#
			# kwin runs the session, so the setting is applied from inside it once the
			# compositor is up. Space is a long way off, but a guest has no input to wake.
			# DPMS MUST BE TURNED ON, AND `kscreen-doctor` IS WHAT TURNS IT, ONCE THE SESSION
			# IS UP. Three attempts were MEASURED before this one worked:
			#
			#  1. `kscreen-doctor --dpms on` called as the session STARTS: it does not fail
			#     politely, it ABORTS - "Aborted (core dumped) kscreen-doctor --dpms on" fills
			#     the console and the screen stays off;
			#  2. writing /sys/class/drm/card0-Virtual-1/dpms directly: not writable by vmuser
			#     (it reads "Off" fine, and writing it is refused);
			#  3. Plasma's power settings (powermanagementprofilesrc, both the Plasma-5
			#     DPMSControl keys and the Plasma-6 Display/turnOffDisplayWhenIdle keys): the
			#     file is written correctly and powerdevil is restarted, and `dpms` still
			#     reads "Off" afterwards.
			#
			# What DOES work, MEASURED: the same kscreen-doctor call, issued once the session
			# has settled. It flips dpms to "On" immediately, and a portal capture taken after
			# it is the real desktop - mean brightness 128.6, identical to the scanout, where
			# the same capture was 0.0 with the display off.
			#
			# So the session wrapper waits for kwin's own socket, then asserts DPMS on, then
			# re-asserts it periodically because Plasma can re-arm its idle timer.
			cat > "$ROOT/opt/kde-session.sh" <<'KSESS'
#!/bin/sh
# Keep the output awake, then run the session. A headless guest has no input to wake a
# blanked screen, and the portal captures exactly what is scanned out - so DPMS off is a
# black frame from a stream that insists it is healthy.
(
	i=0
	# Wait for kwin to own the session bus; kscreen-doctor aborts if it is too early.
	while [ $i -lt 1200 ]; do
		if kscreen-doctor --dpms on >/dev/null 2>&1; then break; fi
		i=$((i + 1)); sleep 0.1
	done
	while :; do
		kscreen-doctor --dpms on >/dev/null 2>&1
		sleep 10
	done
) &
exec /usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasma-wayland
KSESS
			chmod 0755 "$ROOT/opt/kde-session.sh"
			SESSION_CMD='exec /opt/kde-session.sh'
		elif [ "$DESKTOP" = "plasma-mobile" ]; then
			# THE SESSION RUNS - kwin_wayland, plasmashell and plasma-keyboard all come up - AND
			# EASYSTREAM GETS NO FRAME FROM IT.
			#
			# MEASURED with a small probe over the est protocol: Hello was answered at the REAL
			# 1024x768 rather than the default, so the daemon IS attached to kwin's socket, and
			# then no frame ever arrived. MEASURED from the packages: `strings` over
			# kwin_wayland finds ZERO occurrences of zwlr_screencopy and ZERO of
			# ext_image_copy_capture - KWin implements neither, which is why nothing is copied.
			#
			# THE ROUTE THAT EXISTS IS THE PORTAL, AND IT WAS DRIVEN ALL THE WAY TO THE LAST STEP.
			#
			# MEASURED, with xdg-desktop-portal + xdg-desktop-portal-kde + pipewire started and
			# the session bus pushed into the user manager, easystream's own log says:
			#
			#	portal: SelectDevices has NO restore token
			#	        (checked /home/vmuser/.config/remote-desktop-token) - Start will ask for consent
			#	portal: SelectDevices ok
			#	portal: no Response for /org/freedesktop/portal/desktop/request/1_51/est1
			#	portal input: portal ScreenCast unavailable
			#
			# SO EVERYTHING UP TO THE CONSENT DIALOG WORKS. CreateSession returns a session,
			# SelectSources/SelectDevices return 0, and a frame would follow - the ONLY missing
			# consent is the human click on the KDE ScreenCast dialog, and easystream then times
			# out waiting for that Response.
			#
			# THE DIALOG CANNOT BE AUTOMATED FROM HERE, AND THAT WAS MEASURED TOO:
			#   * the permission store cannot be seeded ahead of time: `Set`/`SetPermission` both
			#     answer "Id easystream not found" because the id is created BY the first grant,
			#     so there is nothing to write before a grant has happened once;
			#   * `xdg-permission-store` keeps its table in MEMORY (PermissionDb is not a file),
			#     so even a seeded table would not survive the reboot the test starts with;
			#   * there is no kiosk/auto-approve switch in the KDE backend (searched: no
			#     "auto", "kiosk", or "skip dialog" strings in xdg-desktop-portal-kde);
			#   * the dialog is a KWin surface, so the one screenshot protocol that works here
			#     (wlr-screencopy) cannot capture it to script a click, and no input-injection
			#     tool (wtype/ydotool/kdotool) is in the image to press it blind.
			#
			# THE SESSION IS UNCHANGED AND HEALTHY, AND THE EVIDENCE IS THE SCANOUT, NOT THE
			# PORTAL. Both limits above are about READING THE COMPOSITOR through a protocol;
			# virtio-gpu drives a real framebuffer, so qemu's screendump photographs exactly what
			# KWin scanned out. MEASURED on this image: the Plasma Mobile welcome page over its
			# status bar and navigation bar, at 1024x768, mean brightness 101.6 with a mean
			# deviation of 31.6. The walkthrough's `read the whole screen as "screen"` measures
			# that, which is why this variant ships and is in CI.
			# THE PERMISSION-STORE ROUTE WAS TESTED AND IS ALSO A DEAD END. MEASURED inside the
			# running plasma session: xdg-desktop-portal and plasma-xdg-desktop-portal-kde are both
			# active, the "screencast" table is EMPTY (PermissionStore.List returns []), and an
			# attempt to seed it ahead of time fails at the first step -
			#	PermissionStore.Set -> "Id easystream not found"
			#	PermissionStore.SetPermission -> "Id easystream not found"
			# because the id/table is created BY the first successful grant, not before it. The
			# store persists as a GVDB binary at ~/.local/share/flatpak/db/permissions, so a
			# hand-written grant would have to reproduce that format with keys KDE does not
			# document. And the KDE backend has no kiosk/auto-accept switch (searched: no "kiosk",
			# "auto", "skip dialog" strings), while KWin's screencast is the private
			# zkde_screencast_unstable_v1 protocol that neither easystream nor grim implements.
			#
			# SO THE ONLY WAY LEFT FOR PLASMA IS ONE HUMAN CLICK on the consent dialog - either
			# once by hand to mint a restore token, or with an input device in the guest. A headless
			# boot cannot supply it, and this image cannot forge the token without that first grant.
			# DPMS ON - see the plasma branch for the three measured failures before
			# kscreen-doctor-after-settle turned out to be the one that works.
			cat > "$ROOT/opt/kde-session.sh" <<'KSESS_plasma_mobile'
#!/bin/sh
(
	i=0
	while [ $i -lt 1200 ]; do
		if kscreen-doctor --dpms on >/dev/null 2>&1; then break; fi
		i=$((i + 1)); sleep 0.1
	done
	while :; do
		kscreen-doctor --dpms on >/dev/null 2>&1
		sleep 10
	done
) &
exec /usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasmamobile
KSESS_plasma_mobile
			chmod 0755 "$ROOT/opt/kde-session.sh"
			SESSION_CMD='exec /opt/kde-session.sh'
		elif [ "$DESKTOP" = "plasma-bigscreen" ]; then
			# THE SAME KWIN AS plasma-mobile, AND THE SAME ANSWER: the protocol limits do not
			# apply to the scanout. MEASURED on this image: the TV launcher grid - the clock and
			# date, the tool row, and the application tiles - at 1024x768, mean brightness 57.1
			# with a mean deviation of 23.4. Captured by `read`, like its two siblings.
			# DPMS ON - see the plasma branch for the three measured failures before
			# kscreen-doctor-after-settle turned out to be the one that works.
			cat > "$ROOT/opt/kde-session.sh" <<'KSESS_plasma_bigscreen'
#!/bin/sh
(
	i=0
	while [ $i -lt 1200 ]; do
		if kscreen-doctor --dpms on >/dev/null 2>&1; then break; fi
		i=$((i + 1)); sleep 0.1
	done
	while :; do
		kscreen-doctor --dpms on >/dev/null 2>&1
		sleep 10
	done
) &
exec /usr/lib/plasma-dbus-run-session-if-needed /usr/bin/plasma-bigscreen-wayland
KSESS_plasma_bigscreen
			chmod 0755 "$ROOT/opt/kde-session.sh"
			SESSION_CMD='exec /opt/kde-session.sh'
		elif [ "$DESKTOP" = "budgie" ]; then
			# BUDGIE'S WAYLAND SESSION IS labwc, AND `budgie-desktop` IS NOT ITS ENTRY POINT.
			#
			# MEASURED from the package: usr/share/wayland-sessions/budgie-desktop.desktop has
			#	Exec=/usr/bin/startbudgielabwc
			# and that script ends with
			#	labwc --config-dir .../budgie-desktop/labwc -S budgie-desktop
			# so labwc is the COMPOSITOR and budgie-desktop is a CLIENT it starts. Calling
			# `budgie-desktop` directly asks a panel to attach to a Wayland display nobody
			# created: MEASURED, it printed "Failed to connect to Wayland display" in a loop and
			# never produced a socket or a frame.
			#
			# THE SESSION FILE'S OWN COMMAND IS USED, which also gets its config directory,
			# environment file and menu copied into place - all of which the script does for us.
			SESSION_CMD='exec startbudgielabwc'
		elif [ "$DESKTOP" = "hyprland" ]; then
			# HYPRLAND: the same virtio-gpu device, a different compositor and config language.
			# HYPRLAND 0.57 READS LUA, NOT THE KEY=VALUE FORMAT. MEASURED from the package:
			# /usr/share/hypr/hyprland.lua is its example, and the header says so - there is no
			# hyprland.conf.example any more. MEASURED from the binary: `hyprland --version`
			# reported 0.57.2. The previous file failed with
			#	`/etc/hypr/hyprland.conf:2: unexpected symbol near '#'`
			# because a `#` comment is not Lua; the emergency path still drew the wallpaper and
			# the otter, which is why the screenshot looked like a success.
			#
			# `.lua` EXTENSION, because that is what the parser selects on. `hl.monitor` and
			# `hl.on("hyprland.start", ...)` are the documented forms in that example.
			mkdir -p "$ROOT/etc/hypr"
			cat > "$ROOT/etc/hypr/hyprland.lua" <<'HYPRCFG'
-- NO BAR: hyprland has none built in. The assertion is the terminal opened below, whose
-- title and text are this image's own.
hl.monitor({
    output   = "",
    mode     = "preferred",
    position = "auto",
    scale    = "auto",
})

hl.on("hyprland.start", function ()
    hl.exec_cmd([[foot -T "ARCH HYPRLAND MICROVM" -e sh -c 'echo ARCH HYPRLAND MICROVM; echo compositor: hyprland; echo socket: $WAYLAND_DISPLAY; sleep 3600']])
end)
HYPRCFG
			SESSION_CMD='exec hyprland --config /etc/hypr/hyprland.lua'
		else
			# NOTHING SHOULD REACH HERE: the case at the top of the file already refused any
			# name it does not know. A fallback would silently start hyprland for a typo,
			# which is a worse answer than stopping.
			echo "DESKTOP=$DESKTOP has no session command" >&2
			exit 2
		fi


		cat > "$ROOT/opt/session.sh" <<SESSION
#!/bin/sh
# THE COMPOSITOR ON virtio-gpu, AND NOTHING ELSE. easystream is its own unit.
#
# THE DEVICE IS DISCOVERED, NOT NAMED. card0 is the one device virtio-gpu exposes, and it
# carries both the KMS output and the render node. Waiting for it here keeps the session from
# racing gpu.service, which creates the node.
i=0
while [ \$i -lt 100 ]; do [ -e /dev/dri/card0 ] && break; i=\$((i+1)); sleep 0.1; done
if [ ! -e /dev/dri/card0 ]; then
	echo "session: /dev/dri/card0 never appeared; gpu.service failed" >&2
	exit 1
fi

# THE RUNTIME DIRECTORY BELONGS TO vmuser AND THIS SCRIPT MUST NOT MAKE IT.
#
# MEASURED on plasma-mobile: session.sh started before systemd-logind had created
# /run/user/1000, exported it anyway, and dbus-daemon created the directory as ROOT. Every
# later user child then refused it:
#
#	dbus: Unable to set up transient service directory: XDG_RUNTIME_DIR "/run/user/1000"
#	       is owned by uid 0, not our uid 1000
#
# so the session came up with no bus, no socket discovery and no capture. The wait is for
# logind's own mkdir, which is the only thing allowed to create it.
i=0
while [ \$i -lt 300 ] && [ ! -d /run/user/\$(id -u) ]; do i=\$((i+1)); sleep 0.1; done
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
if [ ! -d "\$XDG_RUNTIME_DIR" ]; then
	echo "session: /run/user/\$(id -u) never appeared; logind did not make it" >&2
	exit 1
fi
export LIBSEAT_BACKEND=noop
export LIBGL_ALWAYS_SOFTWARE=1
# THE SESSION'S OWN TYPE, WHICH MUTTER-BASED COMPOSITORS CHECK BEFORE CHOOSING A BACKEND.
# MEASURED on cinnamon-wayland: without it, cinnamon --replace (the session's compositor)
# restarted every few hundred milliseconds - "App 'cinnamon-wayland.desktop' respawning too
# quickly" - because it did not know it was supposed to bring up a Wayland backend. wlroots
# compositors assume it; the GNOME/Session-manager based ones read it.
export XDG_SESSION_TYPE=wayland
# THE VALUE IS THE DESKTOP'S OWN SPELLING, AND CASE MATTERS TO THE MENUS.
#
# MEASURED on budgie: labwc's own config sets OnlyShowIn=Budgie on BudgiePanel.desktop, and
# that test is CASE-SENSITIVE. startbudgielabwc only forces XDG_CURRENT_DESKTOP=Budgie when
# the variable is empty OR does not already mention budgie case-insensitively - so exporting
# the lowercase name here made it keep "budgie", and the panel was never autostarted. The
# session stayed a bare labwc with its "Config errors detected" bar over an empty desktop.
#
# NO BACKTICKS IN THIS COMMENT. This block is inside an UNQUOTED heredoc (it has to expand
# $DESKTOP), so a backtick would be COMMAND SUBSTITUTED while the image is built - the words
# between them vanished from the emitted script. MEASURED: the first version of this very
# comment did that.
#
# Every desktop whose session files key off this name gets its own spelling.
case "$DESKTOP" in
	budgie) XDG_CURRENT_DESKTOP=Budgie ;;
	xfce|xfce-wayland) XDG_CURRENT_DESKTOP=XFCE ;;
	lxqt|lxqt-wayland) XDG_CURRENT_DESKTOP=LXQt ;;
	plasma|plasma-mobile|plasma-bigscreen) XDG_CURRENT_DESKTOP=KDE ;;
	# CINNAMON'S SESSION NAME IS "X-Cinnamon" IN ITS OWN DESKTOP FILES; muffin forks Mutter's
	# backend selection and reads this to decide it is a Cinnamon session.
	cinnamon|cinnamon-wayland) XDG_CURRENT_DESKTOP=X-Cinnamon ;;
	*) XDG_CURRENT_DESKTOP="$DESKTOP" ;;
esac
export XDG_CURRENT_DESKTOP

# THE WLR_* VARIABLES ARE wlroots', AND HYPRLAND IS NOT wlroots.
#
# MEASURED from the packages: sway and labwc link \libwlroots\; hyprland links its own
# \libaquamarine\, \libhyprlang\ and \libhyprgraphics\ and has no wlroots dependency at
# all. Setting WLR_BACKENDS=... for hyprland is not an error - it is simply ignored, which
# is the worse outcome: the session looks configured and the variable does nothing.
if [ "${DESKTOP}" = "hyprland" ]; then
	# HYPRLAND PICKS THE DRM DEVICE ITSELF through aquamarine, and falls back to the
	# pixman renderer when EGL finds no hardware. Nothing to force.
	export HYPRLAND_NO_CRASHREPORTER=1
elif [ "${DESKTOP}" = "mangowm" ]; then
	# MANGOWM HAS NO PIXMAN PATH: its fx_renderer is EGL-only. MEASURED with WLR_RENDERER=pixman:
	# "Software rendering detected, please use the WLR_RENDERER_ALLOW_SOFTWARE environment
	# variable to proceed", "Failed to initialize EGL context", "couldn't create renderer", and
	# a restart loop. Allowing software lets it take llvmpipe through EGL, which on vkms is the
	# only EGL there is.
	export WLR_BACKENDS=drm
	export WLR_RENDERER_ALLOW_SOFTWARE=1
	export WLR_LIBINPUT_NO_DEVICES=1
	export WLR_XWAYLAND=
elif [ "${DESKTOP}" = "budgie" ]; then
	# BUDGIE'S COMPOSITOR IS labwc - MEASURED from startbudgielabwc, which ends in
	# labwc ... -S budgie-desktop - so it takes wlroots' variables like every other
	# wlroots compositor here.
	export WLR_BACKENDS=drm
	export WLR_RENDERER=pixman
	export WLR_LIBINPUT_NO_DEVICES=1
	export WLR_XWAYLAND=
else
	export WLR_BACKENDS=drm
	export WLR_RENDERER=pixman
	export WLR_LIBINPUT_NO_DEVICES=1
	# NO XWAYLAND: easystream reads Wayland through wlr-screencopy, not the X protocol.
	export WLR_XWAYLAND=
fi

# QTILE'S IMAGE LOADING NEEDS GLYCIN'S SANDBOX OFF. See the long note in the qtile-wayland
# branch above: glycin spawns its loader under bwrap, bwrap cannot set its namespace up in this
# guest, and the failure crashes qtile about four seconds after the session marker - forever.
# MEASURED with this set: no crash. It is exported HERE because this is the script the session
# actually runs, not the build-time block that only chose the command.
if [ "$DESKTOP" = "qtile-wayland" ]; then
	export GLYCIN_DISABLE_SANDBOX=1
fi
unset DISPLAY

# THE SESSION BUS IS STARTED HERE TOO, FOR THE SAME REASON IT IS IN desktop.sh.
#
# MEASURED on Phosh: phosh-session checks DBUS_SESSION_BUS_ADDRESS and, when it is empty,
# wraps the compositor in its own dbus-run-session. That nested bus is not the one a login
# would provide, and gnome-session inside it failed with
#
#	A connection to the bus can't be made
#
# then the session exited and systemd restarted it, forever. Naming the socket first means
# phosh-session finds a bus and runs the compositor directly.
#
# The socket lives where a login puts it, and the wait is for the socket rather than for the
# daemon, so nothing races it.
export DBUS_SESSION_BUS_ADDRESS="unix:path=\$XDG_RUNTIME_DIR/bus"
if [ ! -S "\$XDG_RUNTIME_DIR/bus" ]; then
	dbus-daemon --session --address="\$DBUS_SESSION_BUS_ADDRESS" --nofork --nopidfile &
	i=0
	while [ \$i -lt 100 ]; do [ -S "\$XDG_RUNTIME_DIR/bus" ] && break; i=\$((i+1)); sleep 0.1; done
	if [ ! -S "\$XDG_RUNTIME_DIR/bus" ]; then
		echo "session: the session bus never appeared" >&2
		exit 1
	fi
fi

# THE CAPTURE SERVICE IS TRIGGERED ONCE THE SOCKET EXISTS, AS vmuser.
#
# THIS IS NOT A LIFECYCLE BINDING: easystream stays its own unit with its own
# Restart=on-failure, and this line only starts it. It runs as vmuser so it talks to
# vmuser's own manager.
#
# MEASURED, AND IT IS WHY THE TRIGGER EXISTS: with only
# etc/systemd/user/default.target.wants/easystream.service, the lingered manager came up
# ("Started User Manager for UID 1000") and NEVER STARTED THE UNIT - no easystream process, no
# 48079, no journal line. WantedBy=default.target assumes a session that reaches that
# target, and a linger-only manager stops at basic.target.
#
# AND environment.d DID NOT RELIABLY PUT WAYLAND_DISPLAY WHERE ConditionEnvironment LOOKS,
# which is what the package's own unit checks. Starting it from a process that already knows
# the socket is there removes both uncertainties at once.
(
	# THE SOCKET IS DISCOVERED, NOT ASSUMED. libwayland hands out the first free name, so on a
	# clean boot it is wayland-0 and after a restart it may be wayland-1. MEASURED: sway and
	# labwc on identical images produced different names, and a fixed name broke the one that
	# differed - the capture unit then had no display to attach to and answered every request
	# with a zero-byte png at the default resolution.
	i=0
	WL=
	while [ \$i -lt 600 ]; do
		for f in "\$XDG_RUNTIME_DIR"/wayland-*; do
			case "\$f" in *.lock) continue ;; esac
			[ -S "\$f" ] && { WL=\${f##*/}; break; }
		done
		[ -n "\$WL" ] && break
		i=\$((i+1)); sleep 0.1
	done
	if [ -z "\$WL" ]; then
		echo "session: no compositor socket appeared in 60s" >&2
		exit 1
	fi
	# PUSHED INTO THE MANAGER, because the unit's environment is the manager's environment and
	# environment.d was MEASURED not to reach it.
	# THE SOCKET NAME GOES INTO A FILE THE UNIT READS, NOT INTO THE MANAGER'S ENVIRONMENT.
	#
	# MEASURED, and it is the reason this is a file: systemctl --user set-environment returned
	# 0 from inside session.sh, and systemctl --user show-environment right afterwards printed
	# NOTHING - the manager session.sh talks to is not the one easystream runs under, so the
	# variable reached a manager that owns no process. The unit's own EnvironmentFile= is read
	# by the manager that DOES own the process, so the value cannot land in the wrong place.
	printf 'WAYLAND_DISPLAY=%s\nXDG_RUNTIME_DIR=%s\n' "\$WL" "\$XDG_RUNTIME_DIR" \
		> "\$XDG_RUNTIME_DIR/wl-session.env"
	chmod 0644 "\$XDG_RUNTIME_DIR/wl-session.env"
	echo "session: socket=\$WL runtime=\$XDG_RUNTIME_DIR" >&2
	if [ -f "\$XDG_RUNTIME_DIR/wl-session.env" ]; then
		echo "session: env-file present" >&2
		cat "\$XDG_RUNTIME_DIR/wl-session.env" >&2
	else
		echo "session: env-file MISSING" >&2
	fi
	# THE SESSION BUS REACHES THE UNIT TOO. A compositor that exposes no wlr-screencopy - KWin,
	# weston - leaves easystream to fall back to the ScreenCast portal, and that needs a bus.
	# MEASURED: the unit's environment is the manager's environment, and without this the
	# daemon logs "portal: no session bus" and the frames stay empty even though the portal is
	# running.
	printf 'DBUS_SESSION_BUS_ADDRESS=unix:path=%s\n' "\$XDG_RUNTIME_DIR/bus" >> "\$XDG_RUNTIME_DIR/wl-session.env"
	# THE PORTAL STACK, STARTED BEFORE THE CAPTURE UNIT, for the desktops that have no
	# wlr-screencopy. systemd starts these on demand only when something asks, and easystream's
	# own ask comes through a socket the portal has not opened yet; naming them here removes the
	# race. A missing unit is not a failure, so these may fail harmlessly.
	systemctl --user start pipewire pipewire-pulse wireplumber 2>/dev/null || true
	systemctl --user start xdg-desktop-portal 2>/dev/null || true
	systemctl --user start plasma-xdg-desktop-portal-kde 2>/dev/null || true
	# THE WLR BACKEND, WHICH NEEDS NO CONSENT DIALOG. Only mangowm ships it; the unit is absent
	# elsewhere, and the trailing true keeps that from being an error.
	systemctl --user start xdg-desktop-portal-wlr 2>/dev/null || true
	systemctl --user start xdg-desktop-portal-gnome 2>/dev/null || true
	# RESTARTED, NOT STARTED. The unit can already be active by the time this runs, because
	# default.target.wants puts a link in and a manager that does reach that target starts it
	# with the OLD environment. start on an active unit is a no-op, so the environment set
	# above would never be picked up - MEASURED: labwc kept answering at the default 1920x1080
	# with zero-byte frames while the unit reported itself active.
	i=0
	while [ \$i -lt 100 ]; do
		systemctl --user restart easystream 2>/dev/null && break
		i=\$((i+1)); sleep 0.2
	done
	# Give the restarted unit a moment to attach before the desktop has to be ready.
	sleep 3
) &

# THE CONSOLE MARKER, for the same measured reason as in desktop.sh: MEASURED in CI, a
# walkthrough that waited for the compositor's own name in console.log timed out even though
# the compositor was running and rendering - none of these write to ttyS0. This line is the
# image's own promise that the session got this far.
echo "ARCH-SESSION-STARTING: $DESKTOP"
$SESSION_CMD
SESSION
		chmod 0755 "$ROOT/opt/session.sh"
	else
		# --- THE X11 FAMILY ------------------------------------------------------------
		#
		# XORG ON THE REAL GPU, NOT Xvfb IN MEMORY.
		#
		# Xvfb was the right answer when a microvm had no GPU: it drew into its own heap and
		# needed no DRM node. It has one cost that matters more than the speed it bought -
		# QEMU's VNC exports THE DISPLAY DEVICE, and an X server that renders in a private heap
		# is not on that device, so the console showed a text prompt while the desktop ran
		# somewhere nobody could see.
		#
		# MEASURED on the virtio-gpu display: `modesetting: Driver for Modesetting Kernel
		# Drivers: kms` loads and finds card0; what stopped it was `xf86OpenConsole: Cannot open
		# virtual console 5 (Permission denied)`, because /dev/tty1 is root:tty 0620 and vmuser
		# was not in `tty`. With the group and a logind seat (TTYPath= on session.service, which
		# this family already had) Xorg takes the VT and draws on the scanned-out framebuffer -
		# so the same pixels the console exports are the desktop.
		#
		# `-ac` disables access control: the display is reachable from nowhere but this machine
		# and both sides run as the same uid. `-novtswitch`/`-keeptty` keep Xorg on the VT it was
		# given instead of hunting for another one.
		# DRI3 NEEDS GLAMOR, AND GLAMOR NEEDS TO BE ASKED FOR. MEASURED: without a config the
		# modesetting driver comes up WITHOUT DRI3, and every GL client says
		#
		#	Could not get DRI3 device
		#	Ensure your X server supports DRI3 to get accelerated rendering
		#
		# which is what leaves cinnamon's GL-painted wallpaper black. DRI3 IS BUILT INTO the
		# Xorg binary (`dri3_screen_init` is in /usr/lib/Xorg), so nothing is missing from the
		# package - the extension simply is not initialised until glamor is enabled on a DRM
		# device. The config below is the documented way to ask for it.
		# THE PATH IS /usr/share, NOT /etc. MEASURED from this image's own Xorg output:
		#
		#	(==) Using system config directory "/usr/share/X11/xorg.conf.d"
		#	"/etc/X11/xorg.conf.d"          <- reported as unusable
		#
		# so a file under /etc is read only if the server is allowed there, and here it is not.
		mkdir -p "$ROOT/usr/share/X11/xorg.conf.d"
		cat > "$ROOT/usr/share/X11/xorg.conf.d/20-glamor.conf" <<'XCONF'
Section "Device"
    Identifier  "virtio-gpu"
    Driver      "modesetting"
    Option      "AccelMethod" "glamor"
EndSection

# THE DEPTH IS PART OF THE SAME FIX. MEASURED from the modesetting driver's own strings:
#
#	Cannot use glamor with 24bpp packed fb
#
# and a screen that defaults to depth 24 hands glamor exactly that. Depth 24 with a 32bpp
# XRGB visual is what virtio-gpu's framebuffer actually offers (`virtio_gpudrmfb` formats
# on XRGB8888), so the screen is asked for 24 depth at 32bpp rather than left to default.
Section "Screen"
    Identifier  "virtio-screen"
    Device      "virtio-gpu"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1024x768"
    EndSubSection
EndSection
XCONF
		cat > "$ROOT/opt/session.sh" <<'SESSION'
#!/bin/sh
export XDG_RUNTIME_DIR=/run/user/$(id -u)
# `-configdir` is the default; the file above is what turns glamor (and therefore DRI3) on.
#
# THE LOG GOES TO A FILE AS WELL AS THE CONSOLE, because the questions that matter here -
# did modesetting load, did glamor initialise, was DRI3 registered - are answered in the
# server's own log and are NOT echoed to the console at the default verbosity. MEASURED: the
# console showed only "Using system config directory" and no glamor line at all, which is
# indistinguishable from "config not read" without this file.
exec /usr/lib/Xorg :0 -keeptty -novtswitch -ac -nolisten tcp -logfile /tmp/Xorg.0.log vt1
SESSION
		chmod 0755 "$ROOT/opt/session.sh"

		# CINNAMON'S DESKTOP WAS BLACK BECAUSE ITS WALLPAPER COULD NOT BE DECODED, AND THE
		# COMPOSITOR WAS NEVER THE PROBLEM. MEASURED, and this replaces an earlier guess:
		#
		#   * `muffin` runs fine. Started by hand in the guest it creates an llvmpipe GLX
		#     context (GL_RENDERER: llvmpipe, GL_VERSION 4.6) and reaches its drawing loop. The
		#     "Refusing to try glamor on llvmpipe" line is Xorg declining to accelerate ITS
		#     drawing; it does not stop the X11 compositor, because that compositor uses GLX,
		#     not glamor.
		#   * `_NET_WM_CM_S0` was NOT set in the running session, so the frame really was
		#     background-less - but the reason is the load, not the compositing.
		#
		# THE LOAD, from cinnamon-background-daemon's own journal line:
		#
		#	Failed to load background pixbuf from /usr/share/backgrounds/gnome/adwaita-l.jxl:
		#	glycin-loaders/glycin-jxl/src/main.rs:69:61: Generic Error. Please build `libjxl`
		#	from source (using `vendored` feature) ...
		#
		# The schema's default background is a .jxl, and gdk-pixbuf now decodes images through
		# glycin, whose jxl loader assumes a vendored libjxl that Arch does not ship. The .svg
		# backgrounds DO decode - MEASURED with GdkPixbuf in the guest, both load at 4096x4096 -
		# but the background daemon fails them too, with `glycin-svg.rs:129:10: rendering error:
		# NoMemory`, because a 4096x4096 render does not fit the sandbox's budget.
		#
		# SO THE DESKTOP ASKS FOR NO IMAGE AT ALL and paints a solid colour, which is the one
		# path that needs no decoder and no sandbox. MEASURED after setting this in a live
		# session: zero "Failed to load background pixbuf" lines, and the captured frame went
		# from mean 6.4 to mean 68.2 with #2f4f6f as 661081 of its pixels - a real background
		# under the panel and icons.
		#
		# `picture-uri-list` IS THE KEY THAT WINS, not `picture-uri`. MEASURED: setting
		# picture-uri alone left the frame unchanged, because cinnamon reads the list first and
		# its schema default already populates it. The list entry carries the colour itself.
		if [ "$DESKTOP" = "cinnamon" ]; then
			mkdir -p "$ROOT/etc/dconf/db/local.d" "$ROOT/etc/dconf/profile"
			cat > "$ROOT/etc/dconf/profile/user" <<'DPROFILE'
user-db:user
system-db:local
DPROFILE
			cat > "$ROOT/etc/dconf/db/local.d/00-wallpaper" <<'DWALL'
[org/cinnamon/desktop/background]
picture-uri-list=[{'picture-uri': <'file:///nonexistent.png'>, 'picture-options': <'none'>, 'primary-color': <'#2f4f6f'>, 'color-shading-type': <'solid'>}]
DWALL
			# THE COMPILED DB IS WHAT DCONF ACTUALLY READS, and it is built here rather than
			# left to a package hook because nothing else runs one on a hand-written file.
			# MEASURED: the BUILD HOST has no `dconf`, so `command -v dconf` was false and the
			# db was never compiled - the .d file alone is inert. The binary that exists is the
			# one just installed into $ROOT, so it is run from there under chroot.
			if [ -x "$ROOT/usr/bin/dconf" ]; then
				chroot "$ROOT" /usr/bin/dconf compile /etc/dconf/db/local /etc/dconf/db/local.d || {
					echo "arch-rootfs: dconf compile failed for the cinnamon wallpaper" >&2
					exit 1
				}
			fi
		fi

		case "$DESKTOP" in
		xfce)     SESSION_EXEC=/usr/bin/xfce4-session ;;
		cinnamon) SESSION_EXEC=/usr/bin/cinnamon-session ;;
		lxqt)     SESSION_EXEC=/usr/bin/startlxqt ;;
		mate)     SESSION_EXEC=/usr/bin/mate-session ;;
		i3)       SESSION_EXEC=/usr/bin/i3 ;;
		deepin)   SESSION_EXEC=/usr/bin/dde-session ;;
		# THE X11 SESSION OF A DUAL-STACK DESKTOP. MEASURED from their own xsessions entries:
		# qtile's is `Exec=qtile start` and enlightenment's is `enlightenment_start`. Without
		# these two lines both names fall through to the Wayland branch and the X11 copy of a
		# dual-stack desktop starts the wrong protocol.
		# `qtile start` WITH `-d`: MEASURED, without a config file it answers
		# "usage: qtile [-h] [-v]" and restarts forever, which reads as a broken session
		# rather than a missing default. `-d` uses qtile's own built-in config, which is the
		# thing that draws a bar and makes the screenshot meaningful.
		qtile)         SESSION_EXEC="/usr/bin/qtile start -d" ;;
		enlightenment) SESSION_EXEC=/usr/bin/enlightenment_start ;;
		# THE SESSION FILE'S OWN Exec= LINE, not a guess: gnome-flashback ships
		# `Exec=/usr/lib/gnome-flashback-metacity`, which is a wrapper that starts
		# gnome-session with the flashback components in the right order.
		flashback) SESSION_EXEC=/usr/lib/gnome-flashback-metacity ;;
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
# because xfconf talks to a session D-Bus that nothing had started. dbus-run-session gives
# the whole session one bus, which is what a login would have provided.
#
# THE RUNTIME DIR IS MADE FIRST, BECAUSE dbus-run-session PUTS ITS SOCKET THERE.
# MEASURED on GNOME Flashback with the directory absent: the session restarted forever with
#
#	A connection to the bus can't be made
#
# and nothing else - dbus-run-session could not create its socket, so every child found no bus.
# /run/user/<uid> exists only when login made it; this image makes it itself.
mkdir -p "\$XDG_RUNTIME_DIR"
chmod 700 "\$XDG_RUNTIME_DIR"

# THE BUS IS STARTED EXPLICITLY, WITH A KNOWN ADDRESS, RATHER THAN BY dbus-run-session.
#
# MEASURED on GNOME Flashback: with dbus-run-session, the daemon came up, activated
# org.gtk.vfs.Daemon successfully, and gnome-session STILL answered
#
#	A connection to the bus can't be made
#
# eleven times. dbus-run-session exports DBUS_SESSION_BUS_ADDRESS only to the process it
# execs, and gnome-session's session launcher re-executes its children through a path that
# did not carry it - the daemon was reachable and nothing could find it.
#
# NAMING THE SOCKET IN THE RUNTIME DIR IS THE FORM A LOGIN WOULD PRODUCE, and it is what every
# desktop here is tested against: a fixed path that a child can find without an inherited
# variable.
export DBUS_SESSION_BUS_ADDRESS="unix:path=\$XDG_RUNTIME_DIR/bus"
exec dbus-daemon --session --address="\$DBUS_SESSION_BUS_ADDRESS" --nofork --nopidfile &
DBUS_PID=\$!
i=0
while [ \$i -lt 100 ]; do [ -S "\$XDG_RUNTIME_DIR/bus" ] && break; i=\$((i+1)); sleep 0.1; done
if [ ! -S "\$XDG_RUNTIME_DIR/bus" ]; then
	echo "desktop: the session bus never appeared" >&2
	exit 1
fi
# THE CONSOLE MARKER THE WALKTHROUGH ASSERTS ON.
#
# A DESKTOP MAY LOG NOTHING TO THE SERIAL CONSOLE. MEASURED in CI: the i3 walkthrough waited
# three minutes for "i3-wm" in console.log and never saw it, even though the machine was
# running i3 and a screenshot proved it - i3 writes its banner to its own log, not to ttyS0.
# The same held for the other window managers. Asserting on a desktop's stdout is therefore
# asserting on something the desktop does not promise.
#
# THIS LINE IS A PROMISE THE IMAGE MAKES ITSELF: it prints once, here, after the bus exists
# and immediately before the session manager is exec'd. A machine that never got this far does
# not print it, so it is still a real assertion - it just does not depend on the desktop's own
# logging habits. The name is the image's, not the session's.
# THE ROOT WINDOW, BEFORE THE SESSION MANAGER TAKES OVER.
#
# MEASURED, and it is a hole the Xvfb era hid: on Xorg nothing paints the desktop background
# by itself, so a guest showed its panel and icons over a BLACK field - cinnamon measured mean
# 6.4 and lxqt 9.6, both visibly missing the wallpaper. Xvfb had the same hole; it was simply
# invisible when the console could not show the screen at all.
#
# A flat colour is deliberate: it needs no image file, it makes the frame unambiguously a
# drawn desktop rather than a dead one, and it costs one process that exits immediately.
xsetroot -solid '#2f4f6f' 2>/dev/null || true

# AND AGAIN AFTER THE SESSION MANAGER HAS TAKEN OVER, because a desktop that owns the root
# window overwrites it. Re-applying the colour after a delay puts a real background under the
# panel and icons without fighting anything: a desktop that CAN draw its own still wins, and
# this fills the gap for one that cannot.
(
	# AND IT IS NOT WHAT LEFT CINNAMON'S DESKTOP BLACK. That turned out to be a decoder, not
	# glamor - see the wallpaper note in the session block: the schema's default background is a
	# .jxl that glycin's Arch build cannot decode. The xsetroot retries below are still worth
	# running, because they cost a process that exits and they fill the root window for any
	# desktop that never paints it.
	#
	# THE GLAMOR FACTS, kept because they are true and because the next person will look here
	# first: `AccelMethod "glamor"` loads, gets an OpenGL 4.6 context, and Xorg then says
	#
	#	(II) modeset(0): Refusing to try glamor on llvmpipe
	#	(II) modeset(0): glamor initialization failed
	#
	# because xorg-server's glamor/glamor_egl.c refuses llvmpipe on purpose (commit 0a9415cf79:
	# "the downside of this change is that you lose DRI3 support"), and this guest has no virgl.
	# That costs DRI3 and hardware acceleration; it does NOT stop an X11 compositor, which uses
	# GLX instead - MEASURED: muffin runs and draws on this exact server.
	# The two attempts still matter for the desktops that leave the root window untouched.
	for delay in 12 25 45; do
		sleep \$delay
		xsetroot -solid '#2f4f6f' 2>/dev/null || true
	done
) &

echo "ARCH-SESSION-STARTING: $DESKTOP"
exec $SESSION_EXEC
DESKTOP
		chmod 0755 "$ROOT/opt/desktop.sh"
	fi

	# POLKIT, FOR THE COMPOSITOR THAT ASKS LOGIND FOR CONTROL OF THE MACHINE.
	#
	# MEASURED on cinnamon-wayland: `cinnamon --replace` exited rc=1 in 0.06s, printing only
	#	Access denied as the requested operation requires interactive authentication.
	#	However, interactive authentication has not been enabled by the calling program.
	# The call behind it is logind's TakeControl (muffin binds org.freedesktop.login1.Seat and
	# Session), whose action org.freedesktop.login1.manage defaults to auth_admin_keep - it
	# wants an administrator password through a polkit agent, and a headless session has no agent
	# to prompt and no one to type. The session IS active (loginctl showed Active=yes, State=active
	# on an active VT), so this is not the "scope not active" wall; it is the authentication one.
	#
	# THE RULE GRANTS IT TO THE CONSOLE USER WITH NO PROMPT. vmuser is the only account that can
	# be logged in here and the machine has one display, so an authentication prompt protects
	# nothing real - and without a way to answer it, the compositor can never start.
	if [ "$DESKTOP_FAMILY" != "none" ]; then
		mkdir -p "$ROOT/etc/polkit-1/rules.d"
		cat > "$ROOT/etc/polkit-1/rules.d/49-compositor-take-control.rules" <<'RULE'
// Let the console user take control of the seat without a prompt, so a HEADLESS compositor
// (muffin in cinnamon's Wayland session) can complete TakeControl. Without polkitd running at
// all, the same call is denied the same way, so this file is paired with enabling polkit.
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.login1.manage" && subject.user == "vmuser") {
        return polkit.Result.YES;
    }
});
RULE
	fi

	# A GRIM CAPTURE PROBE, FOR THE COMPOSITORS easystream CANNOT READ.
	#
	# MEASURED: on mangowm, easystream answers "invalid buffer format"/"grab screencopy failed"
	# and the est frame is all zero (max pixel 0), while `grim` against the SAME socket produces a
	# 1024x768 png with 786432 of 786432 pixels non-black and max 255 - the full desktop, the foot
	# window with "ARCH MANGOWM MICROVM" and its focus border. So the compositor DOES draw; it is
	# easystream's shm/format handling that reads black. grim is the capture that works, and it is
	# in the official `extra` repo.
	#
	# This unit runs grim inside the live session and dumps the png as base64 to the console, so
	# the harness can decode it into a real screenshot for a desktop easystream cannot serve.
	case "$DESKTOP" in
	mangowm)
		cat > "$ROOT/etc/systemd/system/grim-probe.service" <<'UNIT'
[Unit]
Description=grab the session with grim and dump it to the console
After=session.service

[Service]
Type=oneshot
User=vmuser
PAMName=login
TTYPath=/dev/tty1
Environment=HOME=/home/vmuser
Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=WAYLAND_DISPLAY=wayland-0
ExecStartPre=/bin/sleep 55
ExecStart=/bin/sh /opt/grim-probe.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT
		ln -sf /etc/systemd/system/grim-probe.service \
			"$ROOT/etc/systemd/system/multi-user.target.wants/grim-probe.service"
		cat > "$ROOT/opt/grim-probe.sh" <<'PSH'
#!/bin/sh
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0
echo "===GRIM START==="
echo "sockets: $(ls /run/user/1000/wayland-* 2>&1 | tr '\n' ' ')"
timeout 15 grim /tmp/grim.png 2>&1; echo "grim-rc=$?"
ls -l /tmp/grim.png 2>&1
echo "---G64---"
base64 /tmp/grim.png 2>/dev/null | fold -w 300 | sed 's/^/G64:/'
echo "===GRIM END==="
PSH
		chmod 0755 "$ROOT/opt/grim-probe.sh"
		;;
	esac


	# --- 3d. THE UNITS --------------------------------------------------------------------
	# A DESKTOP THAT OWNS ITS OWN DISPLAY MANAGER (GDM for gnome) MUST NOT ALSO GET
	# session.service: GDM starts the session on tty1 itself, and a second compositor on the same
	# tty would fight it. DESKTOP_SKIP_SESSION_SERVICE is set by that branch.
	if [ "${DESKTOP_SKIP_SESSION_SERVICE:-0}" != "1" ]; then
	# GLYCIN'S SANDBOX IS OFF FOR QTILE, IN THE UNIT AS WELL AS THE SCRIPT.
	#
	# MEASURED, and it took a second place to make it stick: exporting it in session.sh was NOT
	# enough for the service - qtile still died with the same ImageLoadingError - while the SAME
	# export in an interactive shell ran it fine. The session.sh export stays (it is the honest
	# description of what the desktop needs); this line is what the unit actually honours.
	if [ "$DESKTOP" = "qtile-wayland" ]; then
		SESSION_ENV_EXTRA='Environment=GLYCIN_DISABLE_SANDBOX=1'
	else
		SESSION_ENV_EXTRA=''
	fi
	cat > "$ROOT/etc/systemd/system/session.service" <<UNIT
[Unit]
Description=the session: Xvfb or a Wayland compositor, for vmuser
After=systemd-logind.service
Wants=systemd-logind.service

[Service]
Type=simple
User=vmuser
Environment=HOME=/home/vmuser
$SESSION_ENV_EXTRA
# A LOGIND SESSION, BECAUSE SOME SESSION MANAGERS REQUIRE ONE.
#
# MEASURED on cinnamon-wayland: cinnamon-session answered
#	Could not get session id for session. Check that logind is properly installed and
#	pam_systemd is getting used at login.
# and then "App 'cinnamon-wayland.desktop' respawning too quickly" - it refused to carry on
# because there was no logind session behind it. A plain \`User=\` service has none; \`PAMName=\`
# makes systemd open a PAM session for the unit, which is where pam_systemd registers it and
# where XDG_SESSION_ID and friends come from. Harmless for the desktops that do not need it.
PAMName=login
# A VIRTUAL TERMINAL, SO A COMPOSITOR CAN ACTIVATE ITS OWN SESSION WITHOUT A PROMPT.
#
# MEASURED on cinnamon-wayland, after polkit was granted: the remaining error was
#	muffin-WARNING: Failed to activate session:
#	  org.freedesktop.DBus.Error.InteractiveAuthorizationRequired
# - muffin calls logind's ActivateSession to take over the VT, and logind refuses a session that
# has no TTY at all (loginctl showed TTY= empty), because there is no VT to activate and the
# call is treated as one needing a password. Giving the unit a TTY makes logind attach the
# session to that VT, so the activation is a local VT switch rather than an authenticated call.
# Harmless elsewhere: the desktops that never activate a VT simply never use it.
TTYPath=/dev/tty1
TTYReset=no
TTYVHangup=no
# THE NODE MAY NOT EXIST: the image's /dev is a static directory and systemd sets /dev up as a
# tmpfs, so /dev/tty1 is not there until something makes it. MEASURED: \`ls /dev/tty1\` in the
# built tree answered "No such file or directory". mknod it first, or TTYPath points at nothing.
ExecStartPre=/bin/sh -c 'mkdir -p /dev; [ -e /dev/tty1 ] || mknod /dev/tty1 c 4 1; chmod 620 /dev/tty1; chown root:tty /dev/tty1 2>/dev/null || true'
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
	fi
	# GDM OWNS THE SESSION, SO THE CAPTURE TRIGGER IS ITS OWN UNIT.
	# session.sh (which normally finds the socket, starts the portal and the capture daemon) does
	# not run under GDM, so this unit does that job instead: wait for wayland-0, push its name
	# into the user manager, start the portal stack, and start easystream. It is the same work
	# session.sh does for the session.service desktops.
	if [ "${DESKTOP_SKIP_SESSION_SERVICE:-0}" = "1" ]; then
		cat > "$ROOT/etc/systemd/system/gdm-capture.service" <<'UNIT'
[Unit]
Description=wait for GDM's wayland socket, then start the portal and easystream
After=gdm.service graphical.target
Wants=gdm.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/gdm-capture.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=graphical.target
UNIT
		mkdir -p "$ROOT/etc/systemd/system/graphical.target.wants"
		ln -sf /etc/systemd/system/gdm-capture.service \
			"$ROOT/etc/systemd/system/graphical.target.wants/gdm-capture.service"
		cat > "$ROOT/opt/gdm-capture.sh" <<'GCAP'
#!/bin/sh
# Run as root; drive vmuser's user manager.
U=vmuser; UID_N=$(id -u "$U"); RUNTIME=/run/user/$UID_N
i=0
while [ $i -lt 600 ]; do
	WL=
	for f in "$RUNTIME"/wayland-*; do
		case "$f" in *.lock) continue ;; esac
		[ -S "$f" ] && { WL=${f##*/}; break; }
	done
	[ -n "$WL" ] && break
	i=$((i+1)); sleep 0.1
done
if [ -z "$WL" ]; then echo "gdm-capture: no wayland socket in 60s" >&2; exit 1; fi
echo "gdm-capture: socket=$WL" >&2
# push into the user manager and start the portal + capture, as vmuser
su -s /bin/sh "$U" -c "export XDG_RUNTIME_DIR=$RUNTIME; export DBUS_SESSION_BUS_ADDRESS=unix:path=$RUNTIME/bus; systemctl --user set-environment WAYLAND_DISPLAY=$WL XDG_RUNTIME_DIR=$RUNTIME; systemctl --user start pipewire pipewire-pulse wireplumber 2>/dev/null; systemctl --user start xdg-desktop-portal xdg-desktop-portal-gnome 2>/dev/null; sleep 5; systemctl --user restart easystream 2>/dev/null"

# THE CAPTURE IS THE HARNESS'S `see:`, NOT EASYSTREAM, AND THAT WAS MEASURED RATHER THAN CHOSEN.
#
# xdg-desktop-portal-gnome NOW exposes ScreenCast on this backend (on vkms it answered
# "Non-compatible display server, exposing settings only"), but `Start` answers
#
#	SelectDevices has NO restore token ... Start will ask for consent
#	no Response for /org/freedesktop/portal/desktop/request/1_84/est1
#
# - a consent dialog nobody can click on a headless boot, the same wall KWin has. The two
# shortcuts were tried and both are closed: org.freedesktop.portal.Screenshot also waits for its
# own dialog (measured: GDBus timeout), and calling org.gnome.Shell.Screenshot directly is refused
# by gnome-shell's allowlist ("Screenshot is not allowed"), which only the portal backend holds.
#
# WHAT DOES WORK is the scanout itself: virtio-gpu drives a real framebuffer, so the walkthrough's
# `see:` photographs the desktop the shell actually drew. easystream is still started here so the
# image is complete for an interactive user; it is simply not the evidence.
echo "gdm-capture: done" >&2
GCAP
		chmod 0755 "$ROOT/opt/gdm-capture.sh"
	fi

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

	# THE CAPTURE PROOF FOR A PORTAL-ONLY DESKTOP, INSTALLED IN THE IMAGE.
	#
	# A walkthrough cannot use `see:` for these desktops: `see:` is QEMU's screendump, and
	# the point of this image is that its evidence comes through the desktop's own portal.
	# /opt/portal-capture.sh asks easystream for one frame, decodes the PNG, and exits 0 only
	# when the mean brightness says a desktop was drawn - so a walkthrough's `ssh:` step is
	# the assertion, and its exit status is the verdict.
	#
	# MEASURED on Plasma over virtio-gpu: "portal-capture: PASS mean=133.7 frame=1024x768".
	# The same script on the same guest reports mean=0.0 when DPMS has blanked the output,
	# which is what makes it a real test rather than a file-exists check.
	cat > "$ROOT/opt/portal-capture.sh" <<'PORTALCAP'
#!/bin/sh
# Capture ONE frame through the desktop's own portal and report whether it is a real
# desktop. Runs INSIDE the guest, over ssh, with no screendump anywhere.
#
# Exit 0 = a drawn desktop; non-zero = a black/uniform frame, and the output says which.
#
# WHY THE MEAN IS THE TEST, MEASURED on this image: a healthy Plasma desktop, a desktop
# whose output was in DPMS-off, and a stream that never attached ALL produced a PNG of the
# same 3146804 bytes, because the encoder writes the raw frame size. Size proves nothing;
# brightness does - a real desktop measures ~128, DPMS-off measures 0.0.
set -u

PORT="${EAZYSTREAM_PORT:-48079}"
OUT=/tmp/portal-frame.png
TMPL=/tmp/est-shot-portal.py

# ALWAYS WRITE OUR OWN, WITH THIS ARGUMENT ORDER. MEASURED: an image can already carry a
# /tmp/est-shot.py from an earlier probe, and reusing whatever is there made this script call
# it with the wrong arguments.
cat > "$TMPL" <<'PY'
import socket, struct, sys
port, out = int(sys.argv[1]), sys.argv[2]
s = socket.create_connection(("127.0.0.1", port), timeout=20)
s.settimeout(30)
def recvn(n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise SystemExit("est: connection closed")
        b += c
    return b
s.sendall(struct.pack(">BBI", 0x01, 0, 0))
typ, flags, ln = struct.unpack(">BBI", recvn(6))
if ln:
    recvn(ln)
s.sendall(struct.pack(">BBI", 0x40, 0, 4) + struct.pack(">I", 1) + struct.pack(">B", 0))
for _ in range(900):
    typ, flags, ln = struct.unpack(">BBI", recvn(6))
    payload = recvn(ln) if ln else b""
    if typ == 0x41:
        rid, plen = struct.unpack(">II", payload[:8])
        open(out, "wb").write(payload[8:8+plen])
        sys.exit(0)
raise SystemExit("est: no ShotResp")
PY

python3 "$TMPL" "$PORT" "$OUT" || exit 2
[ -s "$OUT" ] || { echo "portal-capture: no png"; exit 3; }

# THE MEAN BRIGHTNESS, DECODED HERE. A fallback by file size was MEASURED WRONG: a black
# frame and a real desktop both write 3146804 bytes on this image.
read -r MEAN DIMS <<EOF2
$(python3 - "$OUT" <<'PY'
import sys, zlib, struct
d = open(sys.argv[1], "rb").read()
pos, idat, w, h, bd, ct = 8, b"", 0, 0, 0, 0
while pos < len(d):
    ln = struct.unpack(">I", d[pos:pos+4])[0]
    typ = d[pos+4:pos+8]
    data = d[pos+8:pos+8+ln]
    pos += 12 + ln
    if typ == b"IHDR":
        w, h, bd, ct = struct.unpack(">IIBB", data[:10])
    elif typ == b"IDAT":
        idat += data
    elif typ == b"IEND":
        break
raw = zlib.decompress(idat)
ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
stride = w * ch + 1
total = float(0)
n = 0
prev = bytearray(w * ch)
for y in range(h):
    off = y * stride
    f = raw[off]
    row = bytearray(raw[off+1:off+stride])
    if f == 2:
        for i in range(len(row)):
            row[i] = (row[i] + prev[i]) & 0xFF
    elif f in (1, 4):
        for i in range(ch, len(row)):
            row[i] = (row[i] + row[i-ch]) & 0xFF
    prev = row
    if y % 8:
        continue
    for x in range(0, w, 8):
        px = row[x*ch:(x+1)*ch]
        if ch >= 3:
            total += (px[0] + px[1] + px[2]) / 3.0
        else:
            total += px[0]
        n += 1
print("%.1f %dx%d" % (total / max(n, 1), w, h))
PY
)
EOF2

if awk -v m="${MEAN:-0}" 'BEGIN{exit !(m > 5)}'; then
	echo "portal-capture: PASS mean=$MEAN frame=$DIMS"
	exit 0
fi
echo "portal-capture: FAIL mean=${MEAN:-0} (black or DPMS off) frame=$DIMS"
exit 4
PORTALCAP
	chmod 0755 "$ROOT/opt/portal-capture.sh"

	# THE PORTAL FRONTEND MUST KNOW IT IS RUNNING ON KDE, OR IT LOADS NO KDE BACKEND.
	#
	# MEASURED, and this is the fault that survived every other fix: the frontend exposes
	# RemoteDesktop and ScreenCast ONLY when it has selected a backend that provides them,
	# and /usr/share/xdg-desktop-portal/portals/kde.portal is gated by `UseIn=KDE`. The
	# frontend is a systemd user unit, and on this image it starts before the session has
	# exported XDG_CURRENT_DESKTOP, so it chooses nothing and easystream then gets
	#
	#	portal CreateSession: No such interface "org.freedesktop.portal.RemoteDesktop"
	#	                        on object at path /org/freedesktop/portal/desktop
	#
	# while the KDE backend itself is active and healthy on the bus. Restarting the frontend
	# with XDG_CURRENT_DESKTOP=KDE in its environment makes both interfaces appear and the
	# capture work - MEASURED: mean brightness 128.6 through the portal, the same as the
	# scanout. So the variable goes on the UNIT, which is the only place that survives the
	# unit's own early start.
	if [ "$DESKTOP_FAMILY" = "wayland" ] && [ "$DESKTOP" != "gnome" ]; then
		mkdir -p "$ROOT/etc/systemd/user/xdg-desktop-portal.service.d"
		cat > "$ROOT/etc/systemd/user/xdg-desktop-portal.service.d/20-desktop.conf" <<PORTALENV
[Service]
# The KDE portal file is UseIn=KDE; without this the frontend loads no backend and
# RemoteDesktop/ScreenCast are simply absent from the bus.
Environment=XDG_CURRENT_DESKTOP=$([ "$DESKTOP" = "plasma" -o "$DESKTOP" = "plasma-mobile" -o "$DESKTOP" = "plasma-bigscreen" ] && echo KDE || echo "$DESKTOP")
PORTALENV
	fi

	# THE KDE CONSENT DIALOG IS ANSWERED BEFORE THE CAPTURE UNIT ASKS. A oneshot user unit
	# writes the backend's mega-authorisation row (see 3b-ii); easystream then orders after it,
	# so the first portal Start already finds the grant and never opens a dialog. On a
	# non-KDE session the script finds no permission store and exits 0, which is why this is
	# installed for every Wayland desktop rather than only the Plasma ones.
	if [ "$DESKTOP_FAMILY" = "wayland" ]; then
		cat > "$ROOT/etc/systemd/user/kde-mega-auth.service" <<'KAUTH'
[Unit]
Description=grant the portal permission to capture without a consent dialog
Before=easystream.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/kde-mega-auth.sh
StandardOutput=journal+console
StandardError=journal+console
[Install]
WantedBy=default.target
KAUTH
		mkdir -p "$ROOT/etc/systemd/user/default.target.wants"
		ln -sf /etc/systemd/user/kde-mega-auth.service \
			"$ROOT/etc/systemd/user/default.target.wants/kde-mega-auth.service"
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
	# THE SESSION'S OWN NAME IS SET ON THE UNIT FOR BOTH FAMILIES, AND IT IS NOT OPTIONAL.
	#
	# MEASURED, and this is the whole of a Wayland failure that looked like a capture bug: with
	# only the X11 branch writing this file, a Wayland session started easystream with NO
	# WAYLAND_DISPLAY in its environment at all. The packaged `ConditionEnvironment=` lines
	# were cleared by 10-conditions.conf, so nothing stopped it, and it ran with no display to
	# attach to - the est server answered every Hello with the DEFAULT 1920x1080 and every
	# frame came back ZERO BYTES, because there was no surface to copy.
	#
	# `environment.d` is not where this can live: MEASURED, the manager's own
	# `/proc/<manager>/environ` had neither DISPLAY nor WAYLAND_DISPLAY, so the value was never
	# reaching the daemon. A unit `Environment=` is not subject to that lookup.
	if [ "$DESKTOP_FAMILY" = "x11" ]; then
		cat > "$ROOT/etc/systemd/user/easystream.service.d/15-display.conf" <<'DROPIN'
[Service]
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/1000
DROPIN
	else
		cat > "$ROOT/etc/systemd/user/easystream.service.d/15-display.conf" <<'DROPIN'
[Service]
# THE RUNTIME DIRECTORY IS FIXED, THE SOCKET NAME IS NOT, AND `EnvironmentFile=` DOES NOT
# DELIVER IT. MEASURED on this image: /run/user/1000/wl-session.env contains
# WAYLAND_DISPLAY=wayland-1, the drop-in names it, and the running process's /proc/<pid>/environ
# still has only XDG_RUNTIME_DIR - no WAYLAND_DISPLAY at all. A user manager reads its
# EnvironmentFiles when the unit starts, and on this image that read does not take.
#
# So the unit runs a WRAPPER that reads the file itself and execs the daemon with it in the
# environment. That is one place, it is a plain shell read, and it cannot be skipped.
Environment=XDG_RUNTIME_DIR=/run/user/1000
# THE PACKAGED ExecStart IS REPLACED BY THE WRAPPER, WHICH READS wl-session.env ITSELF.
ExecStart=
ExecStart=/opt/easystream-run.sh
DROPIN
	fi

	# THE WRAPPER THAT ACTUALLY CARRIES WAYLAND_DISPLAY. See the drop-in above for why
	# EnvironmentFile= was measured not to deliver it. This reads the file, exports what it
	# finds, and execs the packaged binary - so the daemon sees the compositor's real socket
	# name, and easystream's startup probe chooses the WAYLAND capture path instead of falling
	# back to X11 via a stale DISPLAY.
	if [ "$DESKTOP_FAMILY" = "wayland" ]; then
		cat > "$ROOT/opt/easystream-run.sh" <<'ESRUN'
#!/bin/sh
# Load the compositor's socket name, then become the daemon.
#
# WAIT FOR THE FILE, DO NOT JUST TRY IT. MEASURED: easystream ran at 06:30:22 on a boot
# where session.sh had not written wl-session.env yet, this wrapper read nothing, and the
# daemon fell back - its log said so in as many words. The unit's ExecStartPre only waits
# for a socket to EXIST; the file that names it is written by session.sh a moment later.
ENVF=/run/user/$(id -u)/wl-session.env
i=0
while [ $i -lt 1200 ]; do
	[ -s "$ENVF" ] && break
	i=$((i + 1)); sleep 0.1
done
if [ -r "$ENVF" ]; then
	# The file is KEY=VALUE lines written by session.sh; exporting it as-is is the point.
	set -a
	. "$ENVF"
	set +a
fi
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
	echo "easystream-run: no WAYLAND_DISPLAY in $ENVF after 120s; the probe will fall back" >&2
fi
# DISPLAY MUST NOT WIN THE PROBE. easystream picks X11 when DISPLAY is set and the Wayland
# socket is not, and its X11 path reads Xvfb - which this desktop does not have - so the
# result is a black frame from a healthy-looking daemon. MEASURED.
exec /usr/bin/easystream "$@"
ESRUN
		chmod 0755 "$ROOT/opt/easystream-run.sh"
	fi

	# THE DAEMON'S OWN WORDS REACH THE SERIAL CONSOLE. MEASURED: the packaged unit writes to
	# the journal only, and a console reader sees nothing - so a capture that fails, and WHY it
	# failed (no screencopy, no portal, no bus), is invisible unless somebody is logged in. The
	# capture path is the one thing a microvm exists to prove, so its log belongs on the console
	# beside the boot log.
	cat > "$ROOT/etc/systemd/user/easystream.service.d/05-console.conf" <<'DROPIN'
[Service]
StandardOutput=journal+console
StandardError=journal+console
DROPIN

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