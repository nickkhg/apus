#!/bin/sh
# Runs after the target rootfs is assembled, before it's packed into an image.
set -eu
TARGET_DIR="$1"

cat > "$TARGET_DIR/usr/lib/os-release" <<OSR
NAME="mydistro"
ID=mydistro
PRETTY_NAME="mydistro ${MYDISTRO_VERSION:-dev}"
VERSION_ID="${MYDISTRO_VERSION:-dev}"
OSR

# Mount point for the EFI system partition on installed systems.
mkdir -p "$TARGET_DIR/boot/efi"
