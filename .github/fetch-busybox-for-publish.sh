#!/bin/sh
# Fetch the static busybox ONCE and publish it, so a rootfs build never talks to busybox.net.
#
#   fetch-busybox-for-publish.sh <destination>
#
# WHY THIS EXISTS. Four rootfs scripts (arch, fedora, leap, ubuntu) need a STATIC busybox to be the
# initramfs's first process - an initramfs runs before the root is mounted, so it cannot borrow the
# guest's shell or libc. See the header of make-initramfs.py for why that has to be busybox and not
# systemd.
#
# The binary came from busybox.net on every build, and that host is not always reachable from a
# GitHub runner. MEASURED on 2026-11-26, two separate rootfs jobs died on it:
#
#	rootfs-ubuntu-minimal     curl: (28) Failed to connect to busybox.net port 443
#	rootfs-arch-xfce-wayland     ... after 133013 ms: Could not connect to server
#
# The download is 1.1 MiB and its bytes never change - it is a released static binary from the
# busybox 1.35.0 binaries directory. Re-fetching it per build both wastes the transfer and makes
# every build depend on one host staying up, so it is fetched HERE, checked, and published to the
# same ghcr package that already holds the root filesystems. A build then pulls it like any other
# asset, through `pull-artifact.sh`, which resumes across resets.
#
# THE SHA256 IS PINNED. That is the point of publishing it: the tag `busybox-static` is a claim that
# these exact bytes are the released binary, and a check here is what makes the claim true. If
# upstream ever republished that directory with different bytes, this job fails rather than quietly
# shipping something else.
set -eu

DEST="${1:?destination path}"
URL="https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
WANT_SHA="6e123e7f3202a8c1e9b1f94d8941580a25135382b99e8d3e34fb858bba311348"
WANT_SIZE=1131168

log() { printf '  %s\n' "$*"; }

log "fetching $URL"
# A SHORT CONNECT TIMEOUT AND SEVERAL ATTEMPTS, because this is the one place that still talks to
# busybox.net and the failure it has shown is a connect that hangs rather than one that refuses.
curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors --max-time 180 --connect-timeout 20 \
	-o "$DEST" "$URL"

size=$(wc -c < "$DEST")
[ "$size" = "$WANT_SIZE" ] || {
	echo "ERROR: busybox is $size bytes, expected $WANT_SIZE" >&2
	exit 1
}
sha=$(sha256sum "$DEST" | cut -d' ' -f1)
[ "$sha" = "$WANT_SHA" ] || {
	echo "ERROR: busybox sha256 is $sha, expected $WANT_SHA" >&2
	exit 1
}

# AND IT IS ACTUALLY STATIC, because that is the property the initramfs depends on and a sha256 of
# the wrong file would pass every check above. An interpreter string means the kernel will look for
# a loader that the archive does not carry.
if grep -q -e 'ld-musl' -e 'ld-linux' "$DEST" 2>/dev/null; then
	echo "ERROR: the fetched busybox has an interpreter; it is not static" >&2
	exit 1
fi

chmod 0755 "$DEST"
log "busybox: $size bytes, sha256 $sha, no interpreter"
