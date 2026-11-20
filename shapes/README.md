# shapes/

The machines these walkthroughs start.

**A SHAPE IS WHAT AN `os:` MEANS**: the firmware, the CPU flags, the adapter, the sound card, and
which attached medium marks a boot as an install. `easyvm` reads these INSTEAD of the six it ships
with, which is why this directory exists: a name written here is a machine this repository can start,
and a name it does not write is a refusal rather than something the image happened to carry.

Adding an operating system this build has never heard of is adding a file here - no Go, no new image:
see `internal/machine/shape.go` in `easydev-org/easyvm` for the fields and for the measurements that
fixed each of them.

## The two this repository uses

| File | Machine |
|---|---|
| `microvm.yaml` | no firmware, no PCIe, no display - a kernel and an initramfs handed to qemu |
| `linux.yaml` | the shape a microvm's *installed* disk boots as, when a walk says `os: linux` |

The rest of `easyvm`'s shapes are not copied here on purpose. This directory REPLACES them, so what it
lists is the whole of what these walkthroughs may start - and a distribution guest is not one of them.
