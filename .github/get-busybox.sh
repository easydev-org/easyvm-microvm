#!/bin/sh
# Provide a STATIC busybox for make-initramfs.py, from a source that is up when a runner is up.
#
#   get-busybox.sh <destination>
#
# WHY THIS IS A SHARED SCRIPT RATHER THAN FOUR COPIES OF A curl.
#
# The four rootfs scripts that build an initramfs (arch, fedora, leap, ubuntu) each fetched
#
#	https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox
#
# and that single host failed enough to lose builds. MEASURED on 2026-11-26, two separate rootfs
# jobs (arch-xfce-wayland, ubuntu-minimal) died with
#
#	curl: (28) Failed to connect to busybox.net port 443 after 133013 ms: Could not connect to server
#
# while the same URL answered 200 in about a second from another machine. That is a routing or rate
# problem on the way to one host, and the fix is to stop having one host: busybox.net is tried LAST,
# after the distribution CDN this repository already trusts for alpine.
#
# THE ALPINE PACKAGE IS THE FIRST CHOICE AND IT IS A STATIC BUILD. `busybox-static` is Alpine's own
# package, served from dl-cdn.alpinelinux.org - the same CDN alpine-rootfs.sh already fetches from,
# so a build that can get Alpine can get this. Its payload is `/bin/busybox.static`, which is what
# an initramfs needs: MEASURED, a 1 MiB ELF with no PT_INTERP and no `ld-musl` string, so it runs
# before anything is mounted.
#
# THE APK IS UNPACKED WITH `tar`, NOT `apk`. An .apk is a gzipped tar with two members; extracting
# it needs nothing from Alpine and works from any host.
set -eu

DEST="${1:?destination path}"
ALPINE_VERSION="${ALPINE_VERSION:-3.21}"
# PINNED, because the initramfs is not the place to discover that a new busybox changed a flag.
# The version is in the URL, so a bump is a deliberate edit.
APK="busybox-static-1.37.0-r14.apk"
CDN="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"

log() { printf '  %s\n' "$*"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- 1. the distribution CDN -------------------------------------------------------------
log "fetching $APK from dl-cdn.alpinelinux.org"
if curl -fsSL --retry 4 --retry-delay 2 --retry-all-errors --max-time 180 --connect-timeout 20 \
	-o "$work/bb.apk" "${CDN}/v${ALPINE_VERSION}/main/x86_64/${APK}" 2>/dev/null; then
	if tar -xzf "$work/bb.apk" -C "$work" bin/busybox.static 2>/dev/null \
		&& [ -f "$work/bin/busybox.static" ]; then
		cp "$work/bin/busybox.static" "$DEST"
		chmod 0755 "$DEST"
		log "busybox: got $(wc -c < "$DEST") bytes from the alpine CDN"
		exit 0
	fi
	log "the apk did not contain bin/busybox.static"
fi

# --- 2. the project's own site, as a fallback --------------------------------------------
#
# A SHORT CONNECT TIMEOUT, because the failure this works around is a host that does not answer at
# all: the old line waited 133 s per attempt and five retries on a 300 s budget.
log "falling back to busybox.net"
if curl -fsSL --retry 2 --retry-delay 2 --retry-all-errors --max-time 120 --connect-timeout 15 \
	-o "$DEST" \
	"https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" 2>/dev/null; then
	chmod 0755 "$DEST"
	log "busybox: got $(wc -c < "$DEST") bytes from busybox.net"
	exit 0
fi

log "ERROR: no static busybox could be fetched; the initramfs cannot be built"
exit 1
