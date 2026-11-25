#!/usr/bin/env python3
"""Derive QEMUMICROVM from FreeBSD's FIRECRACKER kernel config.

WHY A SCRIPT AND NOT A PATCH FILE. A hand-written unified diff carries @@ line counts, and the
moment FreeBSD touches `sys/amd64/conf/FIRECRACKER` those counts are wrong and `patch` either
fails or - worse - applies fuzzily somewhere it should not. Every change below is anchored on a
line that must exist, and the script REFUSES rather than guessing when one does not, so a moved
kernel config is a red build instead of a silently different kernel.

WHY THE FILE IS DERIVED AT ALL. FIRECRACKER was written for Firecracker, not for qemu, and one of
its choices does not describe this machine:

	envvar hint.acpi.0.disabled="1"   Firecracker has no ACPI, so switch it off
	device mptable                    ...and describe the CPUs with the legacy MP table

qemu's `hw/i386/microvm.c` builds NO MP table - the string does not appear in it - while
`hw/i386/acpi-microvm.c` publishes a DSDT that enumerates every populated virtio-MMIO slot
(`acpi_dsdt_add_virtio`). A guest that needs its virtio-MMIO disk and network found for it has to
look where qemu actually puts them, which is ACPI.

THE THREE CHANGES, AND NOTHING ELSE:

	acpi disabled        -> left ENABLED      this is the one that matters
	hw.broken_txfifo=1   -> dropped           a Firecracker UART bug; keeping it loses tx irqs
	disable_tsc_calibration -> dropped        qemu exposes kvmclock and an invariant TSC

`device mptable` and `options MPTABLE_LINUX_BUG_COMPAT` stay: PVH CPU bring-up reads the MP table
as a last resort, and removing devices from this config is what the file's own comments warn breaks
the build.
"""
import sys

src = sys.argv[1]
dst = sys.argv[2]

text = open(src).read()

# EACH ENTRY IS (anchor, replacement, what it is for). The anchor must appear EXACTLY ONCE, so a
# duplicated or reworded line cannot be half-changed.
CHANGES = [
    (
        'envvar\thint.acpi.0.disabled="1"',
        '#envvar\thint.acpi.0.disabled="1"\t# QEMU MICROVM HAS ACPI AND ITS VIRTIO-MMIO DEVICES\n'
        '\t\t\t\t\t# ARE ONLY DESCRIBED THERE; see the header of this generator.',
        "leave ACPI enabled, unlike FIRECRACKER",
    ),
    (
        'envvar\thw.broken_txfifo="1"',
        '#envvar\thw.broken_txfifo="1"\t\t# a Firecracker UART emulation bug; qemu has it not',
        "drop the Firecracker UART workaround",
    ),
    (
        'envvar\tmachdep.disable_tsc_calibration="1"',
        '#envvar\tmachdep.disable_tsc_calibration="1"\t# kvmclock + invariant TSC are present',
        "let the kernel calibrate its TSC",
    ),
]

out = text
for anchor, replacement, why in CHANGES:
    n = out.count(anchor)
    if n != 1:
        sys.exit(f"FAILED: {anchor!r} appears {n} times in {src}, expected exactly 1 ({why})")
    out = out.replace(anchor, replacement)

# A GENERATOR THAT CHANGED NOTHING WOULD SHIP A KERNEL IDENTICAL TO THE ROW ABOVE IT. The matrix
# runs both, so an identical pair is a wasted hour rather than a finding.
assert out != text, "the derived config is identical to the source"

header = (
    "# QEMUMICROVM -- generated from FIRECRACKER by .github/freebsd-probe/make-qemumicrovm.py\n"
    "#\n"
    "# THE DIFFERENCE FROM FIRECRACKER IS ACPI: qemu's microvm publishes a DSDT naming every\n"
    "# virtio-MMIO slot and builds no MP table, so hint.acpi.0.disabled must NOT be set.\n"
)
open(dst, "w").write(header + out)
print(f"wrote {dst}")
