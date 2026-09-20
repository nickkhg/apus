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

case "${VM_GPU:-}" in
    "")
        set -- "$@" -nographic ;;
    window)
        set -- "$@" -serial mon:stdio -display cocoa \
            -device virtio-gpu-pci -device virtio-keyboard-pci -device virtio-tablet-pci ;;
    headless)
        rm -f out/vm/monitor.sock out/vm/qmp.sock
        # The same devices as in a window, so that a test can move the
        # pointer. QMP sends the input events; the monitor makes screenshots.
        set -- "$@" -serial mon:stdio -display none \
            -device virtio-gpu-pci -device virtio-keyboard-pci -device virtio-tablet-pci \
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
