# Architecture

mydistro has four layers. Each layer uses the output of the layer before it.

| Layer | Tool | Input | Output | Documentation |
|---|---|---|---|---|
| Packages | `makepkg` | `packages/`, `ui/` | Local pacman repository `[mydistro]` | [packages.md](packages.md) |
| Root file system | `pacstrap` | `rootfs/packages`, `rootfs/overlay/` | A staged root file system | [building.md](building.md) |
| Image | `systemd-repart` | `image/` | `out/live.img` | [system.md](system.md) |
| Installer | `mydistro-install` | The running live system | An installed disk | [system.md](system.md) |

The user interface is a fifth part. It is a set of Swift programs in the `mydistro-ui` package. See [ui.md](ui.md) and [compositor.md](compositor.md).

## Where the work happens

```
Mac (host)
├── make, curl, shasum            downloads and checks the pinned inputs
├── Apple container (builder)     Arch Linux ARM + Swift 6.4
│   ├── makepkg                   builds packages/ into [mydistro]
│   ├── pacstrap                  installs packages into the root file system
│   ├── mkinitcpio                makes the initramfs
│   └── systemd-repart            writes out/live.img
└── QEMU (aarch64, HVF, UEFI)     boots the images, runs the tests
```

The Mac needs only three tools: Apple `container`, QEMU, and `expect` (macOS includes `expect`). All Linux tools run in the builder container.

## Repository layout

| Path | Content |
|---|---|
| `Makefile` | All commands. Run `make help`. |
| `build/Containerfile` | The builder image. |
| `build/build.sh` | The build. It runs in the builder container. |
| `build/cache/` | Downloaded base tarballs and a stamp file. Git ignores this directory. |
| `rootfs/packages` | The packages in the image, one on each line. |
| `rootfs/overlay/` | Files that the build copies into the root file system. |
| `image/repart.d/` | The partition layout of the live image. |
| `image/esp/` | systemd-boot configuration of the live image. |
| `packages/` | Source of the mydistro packages (one `PKGBUILD` in each directory). |
| `ui/` | The Swift package: the compositor, the tools, and the C library modules. |
| `vm/run.sh` | Starts QEMU. |
| `vm/demo.exp` | Starts the compositor in a QEMU window (`make demo`). |
| `tests/` | The automated tests. |
| `out/` | Build results and VM disks. Git ignores this directory. |

## Boot sequence

1. The UEFI firmware (EDK II) finds `EFI/BOOT/BOOTAA64.EFI` on the EFI system partition. This file is systemd-boot.
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
