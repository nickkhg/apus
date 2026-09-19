# mydistro

mydistro is a small Linux distribution for aarch64. Buildroot builds it from source. A live image boots in a VM and installs the system to a disk.

## Requirements

- A Mac with Apple silicon.
- Apple `container` 1.0 or later. Start the service with `container system start`.
- QEMU from Homebrew: `brew install qemu`.

## Quick start

1. Build the live image. The first build takes approximately 15 to 30 minutes. Later builds are incremental.

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

## How it works

The project has three layers:

| Layer | What it does | Where |
|---|---|---|
| Build | Buildroot compiles the kernel, BusyBox, and packages into a root filesystem. | `external/` |
| Image | `genimage` writes a GPT disk image with an EFI partition and the root filesystem. | `external/board/mydistro/genimage.cfg` |
| Installer | A shell script copies the live system to a target disk. | `mydistro-install` |

### Build environment

The build runs in an Apple `container`. The image definition is `build/Containerfile`. It pins the Debian base image by digest and pins the Buildroot release by tag.

The build output goes into two container volumes:

- `mydistro-output` holds the Buildroot output directory.
- `mydistro-dl` holds the downloaded source archives.

The build uses volumes because macOS file systems do not usually make a difference between upper case and lower case in file names. The Linux kernel source contains files whose names differ only in case.

At the end of a build, `build/br.sh` copies `live.img` to `out/` on the Mac.

### Live image

The live image has two partitions:

1. An EFI system partition. It contains GRUB, `grub.cfg`, and the kernel.
2. The root file system (ext4). The live system mounts it read-only.

The kernel command line contains `mydistro.live`. The installer and the login message use this flag to find a live system.

### Installer

The installer is `external/board/mydistro/rootfs-overlay/usr/sbin/mydistro-install`. It does these steps:

1. It finds the disk that the live system booted from.
2. It writes a new GPT partition table to the target disk.
3. It copies the live root partition to the target block by block. Then it makes the file system as large as the partition and gives it a new UUID.
4. It creates a FAT32 EFI partition and copies GRUB and the kernel to it.
5. It writes a `grub.cfg` that points to the new root partition by PARTUUID.
6. It adds the EFI partition to `/etc/fstab` on the new system.

A block copy is possible because the live root file system is read-only.

## Make targets

| Target | Result |
|---|---|
| `make build` | Builds `out/live.img`. |
| `make live` | Boots the live image and a blank 4 GB target disk. |
| `make installed` | Boots only the target disk. |
| `make test` | Runs the full test: install, then boot the installed disk. |
| `make menuconfig` | Opens the Buildroot configuration menu. |
| `make savedefconfig` | Writes the configuration back to `external/configs/`. |
| `make linux-menuconfig` | Opens the kernel configuration menu. |
| `make shell` | Opens a shell in the build container. |
| `make br-<target>` | Runs a Buildroot target. For example, `make br-busybox-rebuild`. |
| `make clean` | Removes the build output. The downloads stay. |
| `make distclean` | Removes the build output, the downloads, and the builder image. |

## Change the system

- To add a package, run `make menuconfig`, select the package, and run `make savedefconfig`. Then run `make build`.
- If you enable an option of a package that Buildroot already built, Buildroot does not build that package again. Run `make br-<package>-reconfigure`, then run `make build`.
- To add or replace files in the root file system, put them in `external/board/mydistro/rootfs-overlay/`.
- To change the kernel configuration, edit `external/board/mydistro/linux.config` or `linux-efi.fragment`.
- To add your own software, put a Buildroot package in `external/package/`.

Run `make test` after each change.
