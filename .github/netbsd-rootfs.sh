#!/bin/sh
# Build the NetBSD root filesystem a microvm boots. Runs on the CI runner (Debian), which has
# mke2fs but no NetBSD tools, so the guest finishes the job on first boot.
set -eu

V="${NETBSD_VERSION:-11.1}"
MIRROR="${NETBSD_MIRROR:-https://ftp.netbsd.org/pub/NetBSD}"
OUT="${1:-.}"
WORK="${OUT}/netbsd-build"

log() { printf '  %s\n' "$*"; }
mkdir -p "$WORK" "$OUT"

# 1. THE TWO PUBLISHED FILES. The MICROVM kernel is in the SAME directory as GENERIC and ships
#    with the release, so nothing is compiled here.
if [ ! -f "$WORK/netbsd-MICROVM" ]; then
	log "fetching netbsd-MICROVM $V"
	curl -fsSL --retry 3 --max-time 300 -o "$WORK/netbsd-MICROVM.gz" \
		"${MIRROR}/NetBSD-${V}/amd64/binary/kernel/netbsd-MICROVM.gz"
	gunzip -c "$WORK/netbsd-MICROVM.gz" > "$WORK/netbsd-MICROVM"
fi

# 2. THE SETS. base + etc is a complete userland: /sbin/init, /bin/sh, /etc/rc, sshd.
for s in base etc; do
	[ -f "$WORK/$s.tar.xz" ] || curl -fsSL --retry 3 --max-time 600 \
		-o "$WORK/$s.tar.xz" "${MIRROR}/NetBSD-${V}/amd64/binary/sets/$s.tar.xz"
done

if [ ! -d "$WORK/root/bin" ]; then
	log "unpacking base and etc"
	rm -rf "$WORK/root"; mkdir -p "$WORK/root"
	# tar CANNOT DECOMPRESS xz HERE: the runner image has no `xz` binary (MEASURED: `tar -xJf`
	# answers "xz: Cannot exec"). python's lzma module is always present with python3.
	python3 - "$WORK" <<'PY'
import sys, tarfile, os
w = sys.argv[1]
for s in ("base", "etc"):
    with tarfile.open(os.path.join(w, s + ".tar.xz")) as t:
        t.extractall(os.path.join(w, "root"), filter="fully_trusted")
PY
fi

R="$WORK/root"

# 3. THE GUEST'S OWN COPIES. /etc/master.passwd is the truth; /etc/pwd.db and /etc/spwd.db are
#    Berkeley DB copies that only pwd_mkdb(8) can write. The build host has neither pwd_mkdb nor
#    NetBSD's crypt(3) - NetBSD 11 hashes with argon2id, which no Linux produces - so `rc.local`
#    regenerates them on first boot. MEASURED: a `$1$` MD5 hash written here fails every login.
log "configuring the guest"
cat > "$R/etc/rc.conf" <<'EOF'
. /etc/defaults/rc.conf
rc_configured=YES
hostname="netbsd"
sshd=YES
dhcpcd=YES
wscons=YES
local=YES
savecore=NO
swap2=NO
fsck=NO
EOF
echo netbsd > "$R/etc/myname"

cat > "$R/etc/fstab" <<'EOF'
/dev/ld0a	/		ext2fs	rw	1 1
kernfs		/kern		kernfs	rw
ptyfs		/dev/pts	ptyfs	rw
procfs		/proc		procfs	rw
tmpfs		/tmp		tmpfs	rw
EOF
mkdir -p "$R/kern" "$R/proc" "$R/tmp" "$R/dev/pts" "$R/home/vmuser"

# THE PASSWORD AND THE HOST KEYS, ONCE, INSIDE THE GUEST.
cat > "$R/etc/rc.local" <<'EOF'
#!/bin/sh
if [ ! -f /var/db/.firstboot-done ]; then
	HASH=$(pwhash admin)
	usermod -p "$HASH" root
	usermod -p "$HASH" vmuser
	pwd_mkdb -p /etc/master.passwd
	ssh-keygen -A
	touch /var/db/.firstboot-done
fi
EOF
chmod 0755 "$R/etc/rc.local"

# 4. vmuser, the account the engine logs in as (the same name every other guest here uses).
python3 - "$R" <<'PY'
import sys, os
r = sys.argv[1]
mp = os.path.join(r, "etc/master.passwd")
lines = open(mp).read().rstrip("\n").split("\n")
if not any(l.startswith("vmuser:") for l in lines):
    lines.append("vmuser:*:1000:100::0:0:vmuser:/home/vmuser:/bin/sh")
    open(mp, "w").write("\n".join(lines) + "\n")
g = os.path.join(r, "etc/group")
s = open(g).read().rstrip("\n")
if "\nvmuser:" not in s:
    open(g, "w").write(s + "\nvmuser:*:1000:\n")
PY

# 5. AUTOLOGIN ON THE SERIAL LINE, SO THE PROMPT IS THE ASSERTION. `gettytab`'s `al` capability
#    is BSD getty's auto-login: getty logs the named user in with no password. A microvm has no
#    keyboard device, so the engine cannot type at a `login:` prompt - the guest must arrive at
#    a shell by itself, which is what alpine's `-l /sbin/autologin` does with busybox.
cat >> "$R/etc/gettytab" <<'EOF'

autologin:\
	:al=vmuser:tc=default:
EOF
python3 - "$R" <<'PY'
import sys, os
r = sys.argv[1]
p = os.path.join(r, "etc/ttys")
out = []
for line in open(p):
    f = line.split()
    if f and f[0] == "constty":
        line = 'constty\t"/usr/libexec/getty autologin"\tvt100\ton secure\n'
    elif f and f[0] == "console":
        line = 'console\t"/usr/libexec/getty Pc"\tvt100\toff secure\n'
    out.append(line)
open(p, "w").write("".join(out))
PY
# A PROMPT THAT NAMES THE USER, because `$ ` alone is what an unfinished boot also looks like.
cat > "$R/home/vmuser/.profile" <<'EOF'
PS1='vmuser@netbsd$ '
EOF
chown -R 1000:100 "$R/home/vmuser"

# 6. THE DISK, AND THE ONE THING ABOUT IT THAT WAS A DEFECT.
#
#    EXT2 AND NOT EXT4, BECAUSE NETBSD HAS AN ext2fs DRIVER AND IT IS FINICKY ABOUT FEATURES. The
#    filesystem is written with `mke2fs -t ext2`, which turns off extents and 64bit but keeps
#    `resize_inode` and `dir_index`; NetBSD mounts that fine TODAY (MEASURED: `mount` answers
#    `/dev/ld0a on / type ext2fs (local)` with no `read-only` flag, and a write to `/root` succeeds).
#
#    THE STATE WORD IS THE DEFECT THIS FILE EXISTS TO NOT REPEAT. `mke2fs` leaves `s_state = 1`
#    (EXT2_VALID_FS), but ANY `e2fsck` pass on the same image can leave `0x2` (EXT2_ERRORS) behind,
#    and NetBSD's ext2fs_vfsops.c turns a filesystem with that bit into a READ-ONLY MOUNT:
#
#	if (fs->e2fs.e2fs_state == E2FS_ISCLEAN) ... else
#		printf("%s: file system not clean; please fsck(8)\n", ...)
#
#    MEASURED on such an image: `/dev/ld0a on / type ext2fs (read-only, local)` and
#    `pwd_mkdb: Cannot open '/etc/pwd.db.tmp': Read-only file system`, so first boot could not make
#    the password hashes or the ssh host keys and the guest fell to a `login:` none could answer.
#    The write below is therefore not cosmetic; it is what makes the disk writable at boot.
#
#    `-I 256` AND NOT `128`: at 128 mke2fs prints "128-byte inodes cannot handle dates beyond 2038
#    and are deprecated". The tree's own files are from the release's 256-byte build, so 256 is also
#    the size they were made for.
log "writing a $(du -sm "$R" | cut -f1) MiB tree into a 2048 MiB ext2 image"
rm -f "$WORK/rootfs.raw"
truncate -s 2048M "$WORK/rootfs.raw"
mke2fs -q -F -t ext2 -b 4096 -I 256 -O ^resize_inode -d "$R" "$WORK/rootfs.raw"
python3 - "$WORK/rootfs.raw" <<'PY'
import struct, sys
f = open(sys.argv[1], "r+b")
f.seek(1024)
sb = f.read(1024)
assert struct.unpack_from("<H", sb, 56)[0] == 0xEF53, "not an ext2 superblock"
if struct.unpack_from("<H", sb, 58)[0] != 1:
    f.seek(1024 + 58)
    f.write(struct.pack("<H", 1))   # EXT2_VALID_FS: without this NetBSD mounts read-only
f.close()
PY

qemu-img convert -f raw -O qcow2 -c "$WORK/rootfs.raw" "$OUT/netbsd.qcow2"
cp "$WORK/netbsd-MICROVM" "$OUT/netbsd-MICROVM"
log "done:"
ls -l "$OUT/netbsd-MICROVM" "$OUT/netbsd.qcow2"
