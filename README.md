# mydistro

mydistro is a Linux distribution for aarch64, based on Arch Linux ARM. It uses systemd and pacman. A live image boots in a VM and installs the system to a disk.

## Requirements

- A Mac with Apple silicon.
- Apple `container` 1.0 or later. Start the service with `container system start`.
- QEMU from Homebrew: `brew install qemu`.

## Quick start

1. Build the live image. The first build downloads approximately 1 GB. Later builds take approximately 1 minute.

   ```sh
   make build
   ```

2. Run the automated test. The test boots the live image, installs to a blank disk, and boots the installed disk.

   ```sh
   make test
   ```

3. Boot the live image yourself. Log in as `root` with no password. Then run `mydistro-install`.

   ```sh
   make live
   ```

4. Boot the installed disk.

   ```sh
   make installed
   ```

To stop QEMU, push `Ctrl-A`, then push `X`.

To install software on a running system, use pacman. For example: `pacman -S htop`.

## How it works

The project has three layers:

| Layer | What it does | Where |
|---|---|---|
| Build | `pacstrap` installs Arch Linux ARM packages into a root file system. | `rootfs/`, `build/build.sh` |
| Image | `systemd-repart` writes a GPT disk image with an EFI partition and the root file system. | `image/` |
| Installer | A shell script and `systemd-repart` copy the live system to a target disk. | `mydistro-install` |

### Build environment

The build runs in an Apple `container` as root. The container needs all capabilities (`--cap-add ALL`) because `pacstrap` mounts file systems.

The builder image is the official Arch Linux ARM root file system. The Makefile downloads the tarball to `build/cache/` and checks its SHA-256 hash. Arch Linux ARM replaces "latest" from time to time. When the hash does not match, the download stops. Examine the new tarball, then update `ALARM_SHA256` in the Makefile.

The build uses two container volumes:

- `mydistro-work` holds the staged root file system and the disk image.
- `mydistro-pkgcache` holds the downloaded packages. Later builds do not download them again.

At the end of a build, `build/build.sh` copies `live.img` and `packages.lock` to `out/` on the Mac. `packages.lock` lists each package and its version.

Arch Linux is a rolling release. Two builds on different days can get different package versions. Use `packages.lock` to compare two builds.

### Live image

The live image has two partitions:

1. An EFI system partition (512 MB). It contains systemd-boot, the kernel, and the initramfs.
2. The root file system (ext4).

The live system boots with `systemd.volatile=overlay`. The root partition stays read-only, and a RAM overlay receives all changes. When you power off, the changes are lost.

The kernel command line also contains `mydistro.live`. The installer and the login message use this flag to find a live system.

### Installer

The installer is `rootfs/overlay/usr/bin/mydistro-install`. It does these steps:

1. It mounts the live partitions read-only. It finds them by their fixed partition UUIDs.
2. It runs `systemd-repart` with the definitions in `/usr/lib/mydistro/repart.d`. This creates the partitions on the target disk and copies the files.
3. It writes `/etc/fstab`. The system mounts the EFI partition at `/boot`, so pacman installs kernel updates where systemd-boot finds them.
4. It writes a systemd-boot entry that points to the new root partition by PARTUUID.

### First boot

On first boot, each installed system does these steps:

- It creates a new machine ID.
- It creates its own pacman keyring (`mydistro-pacman-init.service`).

The build masks `systemd-firstboot` and `systemd-homed-firstboot`. Thus, first boot does not stop to ask questions.

## Make targets

| Target | Result |
|---|---|
| `make build` | Builds `out/live.img`. |
| `make live` | Boots the live image and a blank 8 GB target disk. |
| `make installed` | Boots only the target disk. |
| `make test` | Runs the full test: install, then boot the installed disk. |
| `make shell` | Opens a root shell in the build container. |
| `make clean` | Removes the build output. The package cache stays. |
| `make distclean` | Removes the build output, the package cache, the builder image, and the base tarball. |

## Change the system

- To add a package to the image, add a line to `rootfs/packages`. Then run `make build`.
- To add or replace files in the root file system, put them in `rootfs/overlay/`.
- To change the partition layout of the live image, edit `image/repart.d/`.
- To change the partition layout of installed systems, edit `rootfs/overlay/usr/lib/mydistro/repart.d/`.
- To start a new target disk, remove `out/vm/target.qcow2`.

Run `make test` after each change.
