#!/bin/sh
# Runs from the Buildroot tree after all images are built: assemble live.img.
set -eu
BOARD_DIR="$(dirname "$0")"

install -D -m 0644 "$BOARD_DIR/grub-live.cfg" "$BINARIES_DIR/efi-part/EFI/BOOT/grub.cfg"
support/scripts/genimage.sh -c "$BOARD_DIR/genimage.cfg"
