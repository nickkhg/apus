# Packages

Apus has two kinds of packages:

- Arch Linux ARM packages. `rootfs/packages` lists the packages in the image. pacman installs their dependencies.
- Apus packages. Their source is in `packages/`. The build makes them into a local pacman repository named `apus`.

## Install software on a running system

Use pacman:

```sh
pacman -Syu htop
```

Sync the databases (`-y`) in the same command. The image ships the databases
as they were when it was built, and Arch Linux ARM keeps only the current
version of a package on its mirrors, so `pacman -S` on its own can ask for a
version that is no longer there.

An app that a package installs appears in Summon by itself: pacman installs
the desktop entry of the program, and the compositor reads those. See
[applications.md](applications.md).

## The [apus] repository

Each directory in `packages/` has a `PKGBUILD`. For each directory, `build/build.sh` does these steps:

1. It copies the directory to `/work/pkgbuild/`. For `apus-ui`, it also copies `ui/`.
2. It runs `makepkg` as the user `builder`, with `--nodeps`. The builder image has the build tools. The `depends` array is for the target system.
3. It puts the package in `/work/repo`.

Then `repo-add` makes the repository database. The build copies the repository to `out/repo/`.

`pacstrap` uses a pacman configuration with `[apus]` before `[core]`. Thus, an Apus package takes precedence over an Arch Linux ARM package with the same name.

Current limits:

- The packages are not signed. The repository uses `SigLevel = Optional TrustAll`.
- Installed systems do not have `[apus]` in `/etc/pacman.conf`, because no server publishes the repository. pacman lists Apus packages as foreign packages (`pacman -Qm`). They get no updates.

## apus-release

`apus-release` contains the Apus name and colours.

The Arch `filesystem` package owns `/usr/lib/os-release`. A second package cannot contain the same file. Thus, `apus-release` does these steps:

1. It puts the Apus `os-release` in `/usr/share/apus/os-release`.
2. It adds the pacman hook `apus-branding.hook`. After each install or upgrade of `filesystem` or `apus-release`, the hook copies the Apus `os-release` to `/usr/lib/os-release`.

`/etc/os-release` is a link to `/usr/lib/os-release`. The login banner (`/etc/issue`) contains `\S{PRETTY_NAME}`, so it gets the name from `os-release`. Thus, one file sets the name everywhere.

`pacman -Qkk filesystem` reports `/usr/lib/os-release` as modified. This report is normal for apus.

To change the name or the colours, edit `packages/apus-release/os-release` and increase `pkgrel`.

## apus-ui

`apus-ui` contains the Swift programs in `ui/`. See [ui.md](ui.md).

- The build links the Swift runtime statically. The target system does not need Swift.
- The linker removes the symbols (`-Xlinker --strip-all`). The `PKGBUILD` has `!strip`, because GNU `strip` cannot read the Swift binaries.
- The package installs each `apus-*` program in the SwiftPM output to `/usr/bin`.
- Its dependencies put Mesa, libinput, xkbcommon, libseat, Wayland, FreeType, HarfBuzz, fontconfig, and the DejaVu fonts on the target system.

## Add a package

To add an Arch Linux ARM package to the image:

1. Add its name to `rootfs/packages`.
2. Run `make build` and `make test`.

To add your own package:

1. Make the directory `packages/<name>/` with a `PKGBUILD`.
2. Add `<name>` to `rootfs/packages`.
3. Run `make build` and `make test`.

When you change an Apus package, increase `pkgrel` in its `PKGBUILD`. Installed systems use `pkgrel` to find updates.
