#!/bin/sh
# Runs inside the build container. Thin wrapper around Buildroot's make.
#
#   br.sh build          configure (if needed), build, export images to /src/out
#   br.sh <target>...    any Buildroot make target (menuconfig, linux-menuconfig, ...)
set -eu

BR=/opt/buildroot
O=/work/output
DEFCONFIG=mydistro_aarch64_defconfig

brmake() {
    make -C "$BR" O="$O" BR2_EXTERNAL=/src/external BR2_DL_DIR=/work/dl "$@"
}

# The defconfig in git is the source of truth: re-apply it when it changes.
# (After `make menuconfig`, run `make savedefconfig` to keep your changes.)
if [ ! -f "$O/.config" ] || [ "/src/external/configs/$DEFCONFIG" -nt "$O/.config" ]; then
    brmake "$DEFCONFIG"
fi

if [ "${1:-build}" = build ]; then
    brmake -j"$(nproc)"
    mkdir -p /src/out
    cp "$O/images/live.img" /src/out/live.img
    echo "==> /src/out/live.img ($(du -h /src/out/live.img | cut -f1))"
else
    brmake "$@"
fi
