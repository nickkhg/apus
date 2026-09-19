# mydistro

mydistro is a Linux distribution for aarch64, based on Arch Linux ARM. It uses systemd and pacman. A live image boots in a VM and installs the system to a disk. Its user interface uses Swift 6.4.

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

5. Boot the installed disk in a window, with a display, a keyboard, and a mouse.

   ```sh
   make gui
   ```

To stop QEMU, push `Ctrl-A` in the terminal, then push `X`.

To install software on a running system, use pacman. For example: `pacman -S htop`.

## How it works

The project has four layers:

| Layer | What it does | Where |
|---|---|---|
| Packages | `makepkg` builds the mydistro packages into a local pacman repository. | `packages/` |
| Build | `pacstrap` installs Arch Linux ARM packages and mydistro packages into a root file system. | `rootfs/`, `build/build.sh` |
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

### mydistro packages

Each directory in `packages/` contains a `PKGBUILD`. The build runs `makepkg` for each one as the user `builder`, because `makepkg` does not run as root. Then `repo-add` puts the packages in a local repository named `mydistro`.

`pacstrap` uses the builder's pacman configuration plus the `[mydistro]` repository. The `[mydistro]` repository comes first, so its packages take precedence over Arch Linux ARM packages with the same name. The build copies the repository to `out/repo/`.

The packages are not signed yet. Installed systems do not have the `[mydistro]` repository in `/etc/pacman.conf` yet, because no server publishes it. pacman lists mydistro packages as foreign packages (`pacman -Qm`).

#### mydistro-release

`mydistro-release` contains the mydistro branding. The Arch `filesystem` package owns `/usr/lib/os-release`, so `mydistro-release` cannot contain that file. Instead, it does these steps:

1. It puts the mydistro `os-release` in `/usr/share/mydistro/`.
2. It adds a pacman hook. After each install or upgrade of `filesystem` or `mydistro-release`, the hook copies the mydistro `os-release` to `/usr/lib/os-release`.

`/etc/os-release` is a symlink to `/usr/lib/os-release`. The login banner (`/etc/issue`) reads the name from `os-release`. Thus, one file changes the name everywhere.

`pacman -Qkk filesystem` reports `/usr/lib/os-release` as modified. This report is normal for mydistro.

### User interface (Swift)

The user interface is a Swift package in `ui/`. The plan is to write all of it in Swift: the compositor, the window management, the shell, and the toolkit. Swift uses these C libraries through its C interoperability:

| Purpose | C library | Swift module |
|---|---|---|
| Display modes and buffers (DRM/KMS) | libdrm, GBM | `CDRM`, `CGBM` |
| GPU rendering | EGL, OpenGL ES (Mesa) | `CEGL`, `CGLES` |
| Input devices | libinput, libudev | `CInput`, `CUdev` |
| Keymaps | xkbcommon | `CXKBCommon` |
| Device access for a user session | libseat | `CSeat` |
| Protocol between the compositor and apps | Wayland | `CWaylandServer`, `CWaylandClient` |
| Text | FreeType, HarfBuzz | `CFreeType`, `CHarfBuzz` |

Each C module is a directory in `ui/Sources/` with a `module.modulemap` and a `shim.h`. SwiftPM finds the compiler and linker flags with pkg-config.

The package also has these parts:

- `DRM`: a Swift layer over libdrm. It finds outputs, makes framebuffers, and puts them on the screen.
- `mydistro-display-probe`: it takes control of the screen, draws a test pattern, and then restores the screen.
- `mydistro-ui-check`: it calls each C library once. It needs no display.

The Swift toolchain is the official Swift 6.4.0 build for Fedora 41 (aarch64), in the builder image. Arch uses different names for some libraries, so the builder image adds compatibility links. The Makefile checks the SHA-256 hash of the toolchain tarball.

The `mydistro-ui` package contains the Swift programs. The build links the Swift runtime statically, so the target does not need Swift. The dependencies of the package put the C libraries, Mesa, and the DejaVu fonts on the target.

QEMU from Homebrew has no GPU acceleration. In the VM, Mesa renders with the CPU.

### Swift development loop

1. Edit the Swift code in `ui/`.
2. Run `make ui`. It compiles in the container in a few seconds and copies the programs to `out/ui/`. It does not change the image.
3. Run `make gui` (or `make installed`) and log in as `root`.
4. Run the new build from the shared directory, for example `/mnt/host/ui/mydistro-display-probe`.

The VM gets `out/` from the Mac at `/mnt/host` (read-only, 9p). systemd mounts it when a program first uses it.

To put the UI into the image, run `make build`. The build compiles only the changed Swift files.

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
| `make gui` | Boots the target disk in a window, with a display, a keyboard, and a mouse. |
| `make ui` | Compiles `ui/` and copies the programs to `out/ui/`. |
| `make test` | Runs the install test and the display test. |
| `make shell` | Opens a root shell in the build container. |
| `make clean` | Removes the build output. The package cache stays. |
| `make distclean` | Removes the build output, the package cache, the builder image, and the base tarball. |

## Change the system

- To add an Arch Linux ARM package to the image, add a line to `rootfs/packages`. Then run `make build`.
- To add your own package, make a directory `packages/<name>/` with a `PKGBUILD`. Add `<name>` to `rootfs/packages`. Then run `make build`.
- When you change a mydistro package, increase `pkgrel` in its `PKGBUILD`. Installed systems use `pkgrel` to find updates.
- To change the distribution name or colors, edit `packages/mydistro-release/os-release`.
- To add or replace files in the root file system, put them in `rootfs/overlay/`.
- To change the partition layout of the live image, edit `image/repart.d/`.
- To change the partition layout of installed systems, edit `rootfs/overlay/usr/lib/mydistro/repart.d/`.
- To start a new target disk, remove `out/vm/target.qcow2`.

Run `make test` after each change.

## Tests

`make test` runs two tests. Both use the serial console of the VM.

1. `tests/install.exp` boots the live image and installs to a blank disk. Then it boots the installed disk and checks it.
2. `tests/display.exp` boots the installed disk with a GPU but no window. It runs `mydistro-ui-check` and `mydistro-display-probe`. While the probe draws its pattern on the screen, the test gets a screenshot from QEMU. `tests/screen.py` checks the colours of two pixels.
