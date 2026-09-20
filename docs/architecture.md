# Architecture

mydistro has four layers. Each layer uses the output of the layer before it.

| Layer | Tool | Input | Output | Documentation |
|---|---|---|---|---|
| Packages | `makepkg` | `packages/`, `ui/` | Local pacman repository `[mydistro]` | [packages.md](packages.md) |
| Root file system | `pacstrap` | `rootfs/packages`, `rootfs/overlay/` | A staged root file system | [building.md](building.md) |
| Image | `systemd-repart` | `image/` | `out/live.img` | [system.md](system.md) |
| Installer | `mydistro-install` | The running live system | An installed disk | [system.md](system.md) |

The user interface is a fifth part. It is a set of Swift programs in the `mydistro-ui` package. See [ui.md](ui.md), [compositor.md](compositor.md), [toolkit.md](toolkit.md), and [applications.md](applications.md).

## Where the work happens

```
Mac (host)
├── make, curl, shasum            downloads and checks the pinned inputs
├── Swift 6.4 for macOS           compiles ui/ for mydistro (make ui), with
│                                 the Swift SDK that make sdk exports
├── Xcode (optional)              runs the make targets
├── Apple container (builder)     Arch Linux ARM + Swift 6.4
│   ├── makepkg                   builds packages/ into [mydistro]
│   ├── pacstrap                  installs packages into the root file system
│   ├── mkinitcpio                makes the initramfs
│   └── systemd-repart            writes out/live.img
└── mydistro-vm (Virtualization) boots the images, runs the tests
```

The Mac needs only two tools: Apple `container` and Xcode. macOS includes `expect`, which the tests use. The Makefile downloads the Swift toolchain for macOS into `build/cache/`. All Linux tools run in the builder container.

The builder container mounts the repository at the same path as on the Mac. Thus, paths in compiler messages are correct on the Mac.

## Repository layout

| Path | Content |
|---|---|
| `Makefile` | All commands. Run `make help`. |
| `build/Containerfile` | The builder image. |
| `build/build.sh` | The build. It runs in the builder container. |
| `build/make-sdk.sh` | Makes the Swift SDK for `make ui`. It runs in the builder container. |
| `build/cache/` | Downloaded tarballs, the Swift toolchain for macOS, the Swift SDK, and a stamp file. Git ignores this directory. |
| `rootfs/packages` | The packages in the image, one on each line. |
| `rootfs/overlay/` | Files that the build copies into the root file system. |
| `image/repart.d/` | The partition layout of the live image. |
| `image/esp/` | systemd-boot configuration of the live image. |
| `packages/` | Source of the mydistro packages (one `PKGBUILD` in each directory). |
| `ui/` | The display server: the compositor, the Wayland server, the apps, the tools, and the C library modules. |
| `ui/Apps/` | The app bundles. The package copies them to `/Applications`, and each one becomes an icon in the dock. See [applications.md](applications.md). |
| `ui/Toolkit/` | A Swift package of its own: the toolkit (`Render`, `Toolkit`), the shell UI (`Shell`), and the grid of the terminal (`Terminal`), with their tests. It also builds for macOS. |
| `ui/Protocols/` | The Wayland protocol XML files. |
| `ui/Tools/WaylandScanner/` | The generator of the Swift protocol code. |
| `mydistro.xcodeproj`, `xcode/` | The Xcode project, and the script that its targets run. |
| `vm/` | `mydistro-vm`: the VM on the Mac, with Apple's Virtualization framework. |
| `vm/demo.exp` | Starts the compositor in a window (`make demo`). |
| `tests/` | The automated tests. |
| `out/` | Build results and VM disks. Git ignores this directory. |

## Boot sequence

1. The EFI firmware finds `EFI/BOOT/BOOTAA64.EFI` on the EFI system partition. This file is systemd-boot.
2. systemd-boot reads `loader/loader.conf` and a boot entry. It starts the kernel (`/Image`) with the initramfs.
3. The initramfs uses systemd. It mounts the root partition that `root=PARTUUID=...` identifies.
4. systemd starts the system. On the live system, the root partition stays read-only under a RAM overlay.

## Main versions

| Component | Version |
|---|---|
| Base | Arch Linux ARM (rolling release) |
| Kernel | `linux-aarch64` 7.2 |
| systemd | 261 |
| Swift | 6.4.0 |
| Mesa | 26.2 |
| Wayland | 1.26 |

`out/packages.lock` lists the exact version of each package in the last build.
