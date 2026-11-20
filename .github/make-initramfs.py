#!/usr/bin/env python3
"""Build a minimal initramfs that loads a few modules and switch_roots.

    make-initramfs.py --out FILE --busybox PATH --kver VER \
                      --modules-dir DIR --root DEV [--module NAME ...]

WHY NOT dracut OR mkinitcpio.

Both are correct tools and both need a MOUNTED /proc and /dev/fd to run: dracut
calls `findmnt`, sources module-setup scripts through process substitution, and
mkinitcpio refuses outright with "ERROR: /proc must be mounted!". A container
that cannot mount proc - which is every unprivileged build container, and this
project's own pod - therefore cannot use either.

What those tools produce, for the purpose a microvm needs, is a cpio archive
holding: a shell, the modules that make the root device appear, and a script that
mounts it and hands over. That is small enough to build here directly, and doing
so removes the mount requirement entirely.

THE BUSYBOX IS STATIC, so it brings its own libc and the archive needs no
/usr/lib. It is a separate download rather than taken from the guest because the
guest's own shell links against the guest's libc, which is not on PATH before the
root is mounted.

MODULE DEPENDENCIES ARE THE CALLER'S JOB. The caller knows which kernel it built
against and can read `modules.dep`; guessing here would produce an initramfs that
works on one kernel and silently fails on the next.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

INIT = r"""#!/bin/busybox sh
/bin/busybox --install -s /bin
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# THE MODULES ARE LOADED HERE, BY NAME, because the root device does not exist
# until they are: a microvm has no PCI bus to probe and (with acpi=on) the ACPI
# tables only describe the device once a driver claims it.
for m in @MODULES@; do
	modprobe "$m" 2>/dev/null || insmod "/lib/modules/@KVER@/$m.ko" 2>/dev/null
done

# WAIT FOR THE DEVICE. The kernel creates it asynchronously as drivers bind, so a
# fixed sleep is either too short or wasted; this polls the exact node it needs.
i=0
while [ $i -lt 100 ]; do
	[ -b "@ROOT@" ] && break
	i=$((i + 1))
	sleep 0.1
done

if [ ! -b "@ROOT@" ]; then
	echo "initramfs: @ROOT@ never appeared; the virtio modules did not bind"
	exec /bin/sh
fi

mkdir -p /newroot
mount -t @FSTYPE@ -o rw "@ROOT@" /newroot || {
	echo "initramfs: could not mount @ROOT@ as @FSTYPE@"
	exec /bin/sh
}

# MOVING proc AND sys IS WHAT MAKES THE HANDOVER CLEAN. /dev IS DELIBERATELY NOT
# MOVED: systemd mounts devtmpfs again on the new root, and moving the initramfs's
# copy over it leaves the guest with the nodes that existed BEFORE switch_root -
# which does not include /dev/ttyS0, because the serial driver binds after that.
# MEASURED on openSUSE Leap 16: moving /dev made `Serial Getty on ttyS0` time out
# with "Timed out waiting for device /dev/ttyS0" while the kernel had already
# printed `ttyS0 at I/O 0x3f8 ... is a 16550A`.
for d in proc sys; do
	mount --move "/$d" "/newroot/$d" 2>/dev/null || true
done

exec switch_root /newroot @INIT@
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--busybox", required=True)
    ap.add_argument("--kver", required=True)
    ap.add_argument("--modules-dir", required=True,
                    help="the guest's /lib/modules/<kver>")
    ap.add_argument("--root", default="/dev/vda")
    ap.add_argument("--fstype", default="ext4")
    ap.add_argument("--init", default="/sbin/init")
    ap.add_argument("--module", action="append", default=[],
                    help="a module name, repeatable; .ko[.xz|.gz|.zst] is found for you")
    args = ap.parse_args()

    # THE MODULE FILES ARE COPIED FLAT into /lib/modules/<kver>/<name>.ko, which is
    # what the init script insmods by path. Keeping the deep kernel/ tree would work
    # too, but modprobe needs modules.dep to walk it and there is no depmod here.
    # THE MODULE TREE IS DEEP (kernel/drivers/virtio/...), so the name is SEARCHED
    # FOR rather than addressed directly. The first match wins; a kernel has one
    # module per name.
    index = {}
    for dirpath, _dirnames, filenames in os.walk(args.modules_dir):
        for fn in filenames:
            for ext in (".ko", ".ko.xz", ".ko.gz", ".ko.zst"):
                if fn.endswith(ext):
                    index.setdefault(fn[: -len(ext)], os.path.join(dirpath, fn))
                    break

    wanted = []
    for name in args.module:
        src = index.get(name)
        if not src:
            sys.exit("module %s not found under %s" % (name, args.modules_dir))
        wanted.append((name, src))

    tmp = tempfile.mkdtemp(prefix="initramfs-")
    try:
        os.makedirs(os.path.join(tmp, "bin"))
        os.makedirs(os.path.join(tmp, "proc"))
        os.makedirs(os.path.join(tmp, "sys"))
        os.makedirs(os.path.join(tmp, "dev"))
        os.makedirs(os.path.join(tmp, "newroot"))
        moddst = os.path.join(tmp, "lib/modules", args.kver)
        os.makedirs(moddst)

        shutil.copy2(args.busybox, os.path.join(tmp, "bin/busybox"))
        os.chmod(os.path.join(tmp, "bin/busybox"), 0o755)

        names = []
        for name, src in wanted:
            # A COMPRESSED MODULE IS DECOMPRESSED, because insmod does not open a
            # .ko.xz - that is kmod's job, and kmod is not in this archive.
            dst = os.path.join(moddst, name + ".ko")
            if src.endswith(".xz"):
                subprocess.run(["xz", "-dc", src], stdout=open(dst, "wb"), check=True)
            elif src.endswith(".gz"):
                subprocess.run(["gzip", "-dc", src], stdout=open(dst, "wb"), check=True)
            elif src.endswith(".zst"):
                subprocess.run(["zstd", "-dc", src], stdout=open(dst, "wb"), check=True)
            else:
                shutil.copy2(src, dst)
            names.append(name)

        script = (INIT.replace("@MODULES@", " ".join(names))
                      .replace("@KVER@", args.kver)
                      .replace("@ROOT@", args.root)
                      .replace("@FSTYPE@", args.fstype)
                      .replace("@INIT@", args.init))
        with open(os.path.join(tmp, "init"), "w") as f:
            f.write(script)
        os.chmod(os.path.join(tmp, "init"), 0o755)

        # `--owner 0:0` BECAUSE THE ARCHIVE IS UNPACKED BY THE KERNEL, which does not
        # resolve names; a uid from the build host would be an unrelated user.
        subprocess.run(
            "find . -print0 | cpio --null -o --format=newc --owner 0:0 2>/dev/null | gzip -9 > %s"
            % args.out, shell=True, cwd=tmp, check=True)
        print("initramfs %s: %d module(s), %d bytes"
              % (args.out, len(names), os.path.getsize(args.out)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()