# Building

## Requirements

- A Mac with Apple silicon.
- Apple `container` 1.0 or later. Start the service with `container system start`.
- QEMU from Homebrew: `brew install qemu`.
- Approximately 28 GB of free disk space. The Swift toolchain for macOS and the Swift SDK use approximately 7.5 GB of this.

## Commands

| Command | Result |
|---|---|
| `make build` | Builds `out/live.img`. |
| `make builder` | Builds only the builder image. `make build` does this step when necessary. |
| `make ui` | Compiles `ui/` on the Mac into `out/ui/`. It does not change the image. See [ui.md](ui.md). |
| `make ui-container` | The same as `make ui`, in the builder container. |
| `make sdk` | Gets the Swift toolchain for macOS, and makes the Swift SDK. `make ui` does this step when necessary. |
| `make protocols` | Makes the Wayland protocol code again. See [ui.md](ui.md). |
| `make shell` | Opens a root shell in the builder container. |
| `make clean` | Removes the build output. The package cache stays. |
| `make distclean` | Removes the build output, the package cache, the builder image, and the base tarballs. |

The first build downloads approximately 3 GB. Later builds take approximately 1 minute.

## The builder image

`build/Containerfile` makes the builder image in these steps:

1. It starts from the official Arch Linux ARM root file system tarball.
2. It changes the pacman configuration of the builder. `CheckSpace` and the download sandbox do not work in a container. The image that the build makes keeps the default configuration.
3. It installs `arch-install-scripts`, `base-devel`, `dosfstools`, `e2fsprogs`, and `mtools`.
4. It adds the user `builder`, because `makepkg` does not run as root.
5. It installs the development files of the graphics, input, and text libraries.
6. It adds the Swift 6.4.0 toolchain, and links for the library names that Arch Linux uses.
7. It installs `git`, because SwiftPM gets package dependencies with git.

The builder runs with `--cap-add ALL`, because `pacstrap` and `arch-chroot` mount file systems.

The builder mounts the repository at the same path as on the Mac, for example `/Users/you/Developer/mydistro`. It does not use a short path such as `/src`. Thus, paths in compiler messages are correct on the Mac, and Xcode can open the file of an error.

## Pinned inputs

The Makefile downloads these files and checks their SHA-256 hashes:

| Variable | File |
|---|---|
| `ALARM_SHA256` | `ArchLinuxARM-aarch64-latest.tar.gz` from `os.archlinuxarm.org` |
| `SWIFT_SHA256` | `swift-6.4.0-RELEASE-fedora41-aarch64.tar.gz` from `download.swift.org` |
| `SWIFT_MAC_SHA256` | `swift-6.4.0-RELEASE-osx.pkg` from `download.swift.org`, for `make ui` |

If a hash does not match, the download stops. For the macOS toolchain, the Makefile also checks the package signature with `pkgutil --check-signature`. The signer is "Developer ID Installer: Swift Open Source (V9AUD2URP3)", and Apple notarized the package.

To update the Arch Linux ARM base:

1. Remove `build/cache/ArchLinuxARM-aarch64-latest.tar.gz`.
2. Download the new tarball and its `.md5` file from `os.archlinuxarm.org`. Compare the MD5 values.
3. Calculate the SHA-256 value with `shasum -a 256`. Put it in `ALARM_SHA256`.
4. Run `make build` and `make test`.

To update Swift:

1. Change `SWIFT_VERSION` in the Makefile, and the tarball name in `build/Containerfile`.
2. Download the tarball and its `.sig` file. Check the signature with the Swift keys from swift.org.
3. Put the SHA-256 value in `SWIFT_SHA256`.
4. Download the `.pkg` file for macOS. Check it with `pkgutil --check-signature`. Put its SHA-256 value in `SWIFT_MAC_SHA256`. The two toolchains must have the same version, because the SDK contains the Swift modules of the Linux toolchain.
5. Run `make build`, `make test`, and `make test-dev`.

## Container volumes

The build uses two container volumes. macOS file systems do not usually make a difference between upper case and lower case in file names. Also, they do not keep Linux file owners.

| Volume | Content |
|---|---|
| `mydistro-work` | The staged root file system, the disk image, the local repository, and the Swift build caches. |
| `mydistro-pkgcache` | Downloaded pacman packages. Later builds do not download them again. |

## Build steps

`build/build.sh` runs in the builder container. It does these steps:

1. It removes the output of the last build.
2. It builds each package in `packages/` with `makepkg`, and puts the packages in the local repository `/work/repo`. See [packages.md](packages.md).
3. It makes a pacman configuration that puts `[mydistro]` before the Arch Linux ARM repositories.
4. It installs the packages in `rootfs/packages` with `pacstrap`.
5. It copies `rootfs/overlay/` into the root file system.
6. In a chroot, it makes the initramfs, applies the systemd presets, enables the mydistro services, and masks the first-boot wizards.
7. It moves the contents of `/boot` to a staging directory for the EFI system partition, and adds systemd-boot.
8. It writes the disk image with `systemd-repart`.
9. It copies `live.img`, `packages.lock`, and the repository to `out/`.

## Reproducibility

These inputs do not change:

- The builder base tarball and the Swift toolchain (SHA-256).
- The partition UUIDs and the disk UUID of the live image.

These inputs can change:

- Arch Linux ARM is a rolling release. Two builds on different days can get different package versions. Arch Linux ARM has no archive of old package versions.

Use `out/packages.lock` to compare two builds.

## Disk space

Each change to `build/Containerfile` makes a new builder image. The old images stay. To see the disk use, run `container system df`. To remove images that no container uses, run `container image prune`.

## Old Buildroot version

The first version of mydistro used Buildroot. It is at the git tag `buildroot-v0`. See [decisions.md](decisions.md).
