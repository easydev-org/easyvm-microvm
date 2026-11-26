#!/bin/sh
# Put the static busybox that make-initramfs.py needs at <destination>.
#
#   get-busybox.sh <destination> [<repository>]
#
# THE ASSET IS PULLED FROM THIS REPOSITORY'S OWN ghcr PACKAGE FIRST, and only fetched from
# busybox.net when that is not available. See `fetch-busybox-for-publish.sh` for why it is published
# at all: busybox.net lost two builds in one day, and the bytes never change.
#
# THE FALLBACK IS NOT REDUNDANT. A pull request from a fork cannot read this package, and a registry
# with no `busybox-static` tag yet has nothing to pull - so the direct fetch stays, with the same
# pinned checksum. What changed is which path is normal: a CI build pulls, and only a cold registry
# downloads.
#
# THE PUBLISHED ARTIFACT IS A ONE-MEMBER TAR NAMED `busybox-static`, because `oci-push` mirrors one
# file and `pull-artifact.sh` unpacks a tar. The member name is fixed here so both ends agree.
set -eu

DEST="${1:?destination path}"
REPO="${2:-${GITHUB_REPOSITORY:-}}"
URL="https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
WANT_SHA="6e123e7f3202a8c1e9b1f94d8941580a25135382b99e8d3e34fb858bba311348"
WANT_SIZE=1131168
TAG="busybox-static"

log() { printf '  %s\n' "$*"; }

HERE=$(cd "$(dirname "$0")" && pwd)

verify() {
	size=$(wc -c < "$1")
	sha=$(sha256sum "$1" | cut -d' ' -f1)
	[ "$size" = "$WANT_SIZE" ] && [ "$sha" = "$WANT_SHA" ]
}

# --- 1. the published asset ---------------------------------------------------------------
if [ -n "$REPO" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
	dl=$(mktemp -d)
	if sh "$HERE/pull-artifact.sh" ghcr.io "$REPO" "$TAG" "$dl/$TAG.tar" >/dev/null 2>&1; then
		if tar -xf "$dl/$TAG.tar" -C "$dl" "$TAG" 2>/dev/null && [ -f "$dl/$TAG" ]; then
			if verify "$dl/$TAG"; then
				cp "$dl/$TAG" "$DEST"
				chmod 0755 "$DEST"
				rm -rf "$dl"
				log "busybox: pulled $TAG from ghcr.io/$REPO ($WANT_SIZE bytes, checksum ok)"
				exit 0
			fi
			log "the published $TAG failed its checksum; fetching directly instead"
		else
			log "the published $TAG is not a tar holding $TAG; fetching directly instead"
		fi
	fi
	rm -rf "$dl"
fi

# --- 2. the project's own site ------------------------------------------------------------
log "fetching busybox from busybox.net"
curl -fsSL --retry 4 --retry-delay 3 --retry-all-errors --max-time 180 --connect-timeout 20 \
	-o "$DEST" "$URL"
verify "$DEST" || {
	echo "ERROR: the fetched busybox failed its checksum or size" >&2
	echo "  got  $(wc -c < "$DEST") bytes, $(sha256sum "$DEST" | cut -d' ' -f1)" >&2
	echo "  want $WANT_SIZE bytes, $WANT_SHA" >&2
	exit 1
}
chmod 0755 "$DEST"
log "busybox: fetched $WANT_SIZE bytes from busybox.net (checksum ok)"
