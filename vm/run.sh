#!/bin/sh
# Boot mydistro in QEMU (aarch64, UEFI, hardware-accelerated via HVF).
#
#   vm/run.sh live        live image + blank target disk (to test the installer)
#   vm/run.sh installed   target disk only (boot what the installer wrote)
#
# VM_GPU selects the display:
#   (unset)    no display device; serial console only
#   window     virtio-gpu in a macOS window, plus keyboard and tablet (mouse)
#   headless   virtio-gpu with no window, plus keyboard and tablet;
#              `screendump` on out/vm/monitor.sock, input events on out/vm/qmp.sock
#              saves the screen (used by tests/display.exp)
#
# VM_RES sets the size of the screen, for example VM_RES=1920x1200. It is the
# preferred mode of the virtual display, and the compositor takes that mode.
# The tests use the default, because they look at pixels at known places.
#
# The window mode scales the picture to the window, so the macOS window can be
# dragged to any size. The screen of the guest keeps the size of VM_RES: the
# compositor reads the mode when it starts and does not follow a change. On a
# screen with two pixels to the point, a guest screen of 1280x800 fills half
# of the window that macOS gives it, so a larger VM_RES makes a sharper
# picture and a smaller user interface, because one point is still one pixel.
#
# The serial console is always on stdio. Quit QEMU with Ctrl-A X.
# out/ on the Mac is shared read-only with the VM at /mnt/host.
set -eu
cd "$(dirname "$0")/.."

mode="${1:-live}"
LIVE=out/live.img
TARGET=out/vm/target.qcow2
TARGET_SIZE=${TARGET_SIZE:-8G}

fw_dir="$(brew --prefix qemu)/share/qemu"
mkdir -p out/vm
[ -f "$TARGET" ] || qemu-img create -q -f qcow2 "$TARGET" "$TARGET_SIZE"

# Fresh UEFI variable store every boot: firmware falls back to the removable
# media path (EFI/BOOT/BOOTAA64.EFI), exactly like a new machine would.
cp "$fw_dir/edk2-arm-vars.fd" out/vm/vars.fd

set -- \
    -M virt -accel hvf -cpu host -smp 4 -m 2G \
    -drive if=pflash,format=raw,readonly=on,file="$fw_dir/edk2-aarch64-code.fd" \
    -drive if=pflash,format=raw,file=out/vm/vars.fd \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -virtfs local,path="$PWD/out",mount_tag=host,security_model=none,readonly=on

# The display device, with the screen size that VM_RES asks for.
resolution="${VM_RES:-1280x800}"
case "$resolution" in
    [0-9]*x[0-9]*) ;;
    *) echo "VM_RES must be WIDTHxHEIGHT, for example 1920x1200" >&2; exit 2 ;;
esac
gpu="virtio-gpu-pci,xres=${resolution%x*},yres=${resolution#*x}"

case "${VM_GPU:-}" in
    "")
        set -- "$@" -nographic ;;
    window)
        # zoom-to-fit lets the macOS window be dragged to any size: QEMU
        # scales the picture. The screen of the guest keeps the size that
        # VM_RES set, so the compositor never sees the mode change.
        set -- "$@" -serial mon:stdio -display cocoa,zoom-to-fit=on \
            -device "$gpu" -device virtio-keyboard-pci -device virtio-tablet-pci ;;
    headless)
        rm -f out/vm/monitor.sock out/vm/qmp.sock
        # The same devices as in a window, so that a test can move the
        # pointer. QMP sends the input events; the monitor makes screenshots.
        set -- "$@" -serial mon:stdio -display none \
            -device "$gpu" -device virtio-keyboard-pci -device virtio-tablet-pci \
            -monitor unix:out/vm/monitor.sock,server,nowait \
            -qmp unix:out/vm/qmp.sock,server,nowait ;;
    *) echo "VM_GPU must be empty, 'window' or 'headless'" >&2; exit 2 ;;
esac

case "$mode" in
    live)
        [ -f "$LIVE" ] || { echo "no $LIVE - run 'make build' first" >&2; exit 1; }
        # snapshot=on: the live image is never modified by a boot.
        set -- "$@" \
            -drive if=virtio,format=raw,file="$LIVE",snapshot=on \
            -drive if=virtio,format=qcow2,file="$TARGET"
        ;;
    installed)
        set -- "$@" -drive if=virtio,format=qcow2,file="$TARGET"
        ;;
    *) echo "usage: $0 live|installed" >&2; exit 2 ;;
esac

exec qemu-system-aarch64 "$@"
