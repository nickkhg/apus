#!/bin/bash
# Runs inside the build container (as root, with --cap-add ALL).
# Assembles the Apus root file system with pacstrap and packs it into a
# bootable GPT disk image with systemd-repart.
#
#   $PWD    this repository (bind mount, same path as on the host)
#   /work   scratch space (container volume, case-sensitive ext4)
set -euo pipefail

SRC=$PWD
REPO=/work/repo
STAGE=/work/stage
ROOT=$STAGE/rootfs
ESP=$STAGE/esp
IMG=/work/live.img

step() { echo; echo "==> $*"; }

step "Cleaning previous stage"
umount -R "$ROOT" 2>/dev/null || true
rm -rf "$STAGE" "$IMG"
mkdir -p "$ROOT" "$ESP"
mount --bind "$ROOT" "$ROOT"     # pacstrap wants the root to be a mount point

step "Installing package build requirements"
# What packages/*/PKGBUILD need to build, but the target does not need to
# run. They are here and not in the builder image because the image adds the
# two toolchain tarballs, and a rebuild of it has to send them both to the
# container tool, which truncates a context that large. /var/cache/pacman/pkg
# is a volume, so this downloads once.
pacman -Sy --noconfirm --needed \
    meson ninja cmake python-mako python-packaging python-yaml \
    glslang spirv-tools expat zlib zstd vulkan-headers vulkan-icd-loader \
    libx11 libxext libxdamage libxfixes libxshmfence libxxf86vm libxrandr \
    xorgproto libxcb

step "Building Apus packages"
# Every packages/<name>/PKGBUILD becomes a package in the local [apus]
# repository. makepkg won't run as root, so it runs as `builder`.
rm -rf /work/pkgbuild "$REPO"
mkdir -p /work/pkgbuild "$REPO"
cp -r "$SRC/packages/." /work/pkgbuild/
# The Swift UI package builds from ui/ (without any local .build directory).
# makepkg runs with --nodeps: build requirements (e.g. Swift) come from the
# builder image, and `depends` are for the target, not the builder.
tar -C "$SRC" --exclude=.build -cf - ui | tar -C /work/pkgbuild/apus-ui -xf -
mkdir -p /work/swiftpm
chown -R builder: /work/pkgbuild "$REPO" /work/swiftpm
for dir in /work/pkgbuild/*/; do
    name=$(basename "$dir")
    (cd "$dir" && runuser -u builder -- env PKGDEST="$REPO" SWIFT_SCRATCH="/work/swiftpm/$name" \
        makepkg --clean --cleanbuild --force --nodeps)
done
repo-add --quiet "$REPO/apus.db.tar.gz" "$REPO"/*.pkg.tar.*

# pacman config for pacstrap: the builder's, plus [apus] listed first so
# our packages take precedence. Packages are not signed yet.
awk '/^\[core\]/ { print "[apus]\nSigLevel = Optional TrustAll\nServer = file://'"$REPO"'\n" } { print }' \
    /etc/pacman.conf > /work/pacman.conf

step "Installing packages"
mapfile -t packages < <(sed -e 's/#.*//' -e '/^\s*$/d' "$SRC/rootfs/packages")
# -c: use the builder's package cache (a volume, so downloads are kept)
# -G: don't copy the builder's keyring (each system makes its own, see
#     apus-pacman-init.service)
# -M: don't copy the builder's mirrorlist (use the package default)
pacstrap -C /work/pacman.conf -c -G -M "$ROOT" "${packages[@]}"

step "Applying rootfs overlay"
cp -r --no-preserve=ownership "$SRC/rootfs/overlay/." "$ROOT/"

step "Configuring the system"
arch-chroot "$ROOT" /bin/bash -euo pipefail <<'EOF'
mkinitcpio -P
rm -f /boot/initramfs-linux-fallback.img
# Apply the distribution's presets now, so first boot enables nothing new.
systemctl preset-all
systemctl enable systemd-networkd systemd-resolved apus-pacman-init \
    mnt-host.automount mnt-screens.automount
# First boot must not stop at an interactive wizard. Locale, time zone and
# hostname are preset, and root has no password.
systemctl mask systemd-firstboot.service systemd-homed-firstboot.service
passwd -d root
EOF
# The time zone of the image. The Makefile passes TIMEZONE; `timedatectl
# set-timezone` changes it on a running system.
ln -sf "../usr/share/zoneinfo/${TIMEZONE:-UTC}" "$ROOT/etc/localtime"
ln -sf ../run/systemd/resolve/stub-resolv.conf "$ROOT/etc/resolv.conf"
# Every machine gets its own ID on first boot.
echo uninitialized > "$ROOT/etc/machine-id"
pacman --root "$ROOT" -Q > "$STAGE/packages.lock"
umount "$ROOT"

step "Assembling the EFI system partition"
# /boot (kernel, initramfs) moves to the ESP. Installed systems mount the ESP
# at /boot, so kernel updates from pacman land where systemd-boot finds them.
# The live root keeps an empty /boot as the mount point.
find "$ROOT/boot" -mindepth 1 -maxdepth 1 -exec mv -t "$ESP/" {} +
mkdir -p "$ESP/EFI/BOOT" "$ESP/EFI/systemd"
cp "$ROOT/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" "$ESP/EFI/BOOT/BOOTAA64.EFI"
cp "$ROOT/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" "$ESP/EFI/systemd/"
cp -r "$SRC/image/esp/." "$ESP/"

step "Writing disk image"
# --offline: build file systems with mkfs.* -d / mcopy, no loop devices.
# Fixed seed: same inputs give the same disk and partition UUIDs.
systemd-repart --empty=create --size=auto --offline=yes --dry-run=no \
    --seed=6d79646f-0000-4000-8000-000000000000 \
    --root="$STAGE" --definitions="$SRC/image/repart.d" "$IMG"

mkdir -p "$SRC/out"
cp --sparse=always "$IMG" "$SRC/out/live.img"
cp "$STAGE/packages.lock" "$SRC/out/packages.lock"
rm -rf "$SRC/out/repo"
cp -r "$REPO" "$SRC/out/repo"
step "Done: out/live.img ($(du -h --apparent-size "$IMG" | cut -f1)), $(wc -l < "$STAGE/packages.lock") packages"
