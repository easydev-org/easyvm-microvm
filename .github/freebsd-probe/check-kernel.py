#!/usr/bin/env python3
"""Assert that a kernel can be handed to `qemu -kernel` on a microvm, and say which way.

WHY THIS EXISTS RATHER THAN A GREP. The first version of this check was

	if grep -qi 'Xen' /tmp/notes.txt; then echo "PVH note present"

and it was WRONG IN THE WAY THAT MATTERS: a FreeBSD kernel carries a dozen Xen ELF notes -
GUEST_OS (6), GUEST_VERSION (7), XEN_VERSION (5), VIRT_BASE (3), LOADER (10), BSD_SYMTAB (12) and
more - and `grep Xen` matches every one of them. qemu does not read any of those. It reads ONE:

	XEN_ELFNOTE_PHYS32_ENTRY, note type 18, a 4-byte descriptor holding the 32-bit physical entry

`hw/i386/x86-common.c` looks the note up by TYPE, and answers

	Error loading uncompressed kernel without PVH ELF Note

when it is absent. So the check has to be the type, not the owner string.

AND IT HAS TO PARSE, NOT GREP, BECAUSE `readelf -n` PRINTS `Unknown note type: (0x00000012)`.
Note 18 is not one of the types binutils has a name for, so the only way to see it is to compare
the number - and the only way to see it RELIABLY is to read the note section yourself instead of
trusting a line-oriented dump that a `head` can truncate. That is exactly how the first run's own
log hid the answer from me.

THE BOOT PROTOCOLS QEMU TRIES, in order, and what each needs:

	Linux boot protocol   "HdrS" at file offset 0x202          Linux only
	Multiboot v1          magic 0x1BADB002 in the first 8 KiB 32-bit ELF only
	PVH                   ELF note type 18                    what FreeBSD has

PROVES: THE KERNEL CAN BE LOADED AND ENTERED. That is what the note says and all it says.
DOES NOT PROVE: that it boots. MEASURED, and this is the counterexample that keeps the check
honest: `netbsd-GENERIC` carries the same `XEN_ELFNOTE_PHYS32_ENTRY` (type 18) as
`netbsd-MICROVM`, and it still does not boot on a microvm - qemu enters it and nothing comes
back. The difference between those two kernels is not the note, it is what they were BUILT
with: MICROVM has `virtio_mmio`, `virtio_blk` and its filesystems compiled in, GENERIC expects
a PCI bus it will never find. A note in the header says where to jump; it says nothing about
whether the machine on the other side exists.

So a pass here means "worth trying to boot", and the boot gate is what answers the rest.
"""
import struct
import sys

path = sys.argv[1]
data = open(path, "rb").read()

assert data[:4] == b"\x7fELF", f"{path} is not an ELF"
assert data[4] == 2, "not ELFCLASS64"
assert struct.unpack_from("<H", data, 18)[0] == 62, "not EM_X86_64"

# --- the section headers, to find SHT_NOTE sections ---------------------------------------
e_shoff = struct.unpack_from("<Q", data, 40)[0]
e_shentsize = struct.unpack_from("<H", data, 58)[0]
e_shnum = struct.unpack_from("<H", data, 60)[0]
e_shstrndx = struct.unpack_from("<H", data, 62)[0]


def section(i):
    o = e_shoff + i * e_shentsize
    name, stype = struct.unpack_from("<II", data, o)
    offset, size = struct.unpack_from("<QQ", data, o + 24)
    return name, stype, offset, size


_, _, stroff, strsize = section(e_shstrndx)
shstrtab = data[stroff:stroff + strsize]


def sh_name(i):
    o = e_shoff + i * e_shentsize
    n = struct.unpack_from("<I", data, o)[0]
    end = shstrtab.find(b"\0", n)
    return shstrtab[n:end].decode("ascii", "replace")


# --- every note in every SHT_NOTE section --------------------------------------------------
# An ELF note is: namesz(u32) descsz(u32) type(u32) name(align4) desc(align4)
notes = []
for i in range(e_shnum):
    name, stype, off, size = section(i)
    if stype != 7:  # SHT_NOTE
        continue
    sect = sh_name(i)
    p, end = off, off + size
    while p + 12 <= end:
        namesz, descsz, ntype = struct.unpack_from("<III", data, p)
        p += 12
        owner = data[p:p + namesz].rstrip(b"\0").decode("ascii", "replace")
        p += (namesz + 3) & ~3
        desc = data[p:p + descsz]
        p += (descsz + 3) & ~3
        notes.append((sect, owner, ntype, desc))

print(f"{path}: ELF64 EM_X86_64, {len(data)} bytes, {len(notes)} ELF notes")
for sect, owner, ntype, desc in notes:
    tag = ""
    if ntype == 18:
        tag = "  <-- XEN_ELFNOTE_PHYS32_ENTRY (PVH)"
    print(f"  {sect:<20} {owner:<6} type {ntype:<3} descsz {len(desc):<4}{tag}")

# --- the three protocols ------------------------------------------------------------------
pvh = [n for n in notes if n[1] == "Xen" and n[2] == 18]
multiboot = data.find(struct.pack("<I", 0x1BADB002), 0, 8192) >= 0
linuxboot = data[0x202:0x206] == b"HdrS"

found = []
if pvh:
    entry = struct.unpack_from("<I", pvh[0][3], 0)[0]
    found.append(f"PVH (note type 18, phys32 entry {entry:#x})")
if multiboot:
    found.append("Multiboot v1")
if linuxboot:
    found.append("Linux boot protocol")

if not found:
    print("FAILED: the kernel speaks none of the protocols qemu -kernel implements")
    print("        (a microvm has no firmware, so there is no other way in)")
    sys.exit(1)

print("boot protocols qemu -kernel can use: " + ", ".join(found))
