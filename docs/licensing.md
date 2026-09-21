# Licensing

## The code in this repository

Apus is under the Apache License 2.0. [LICENSE](../LICENSE) holds the full text.

A person who takes this code can use it, change it, and sell work that they build on it. That person must keep the copyright notice, and must say which files they changed. The license also gives a patent license from each contributor.

## Code from other projects

Two parts of `ui/` come from the Wayland project:

| Files | Source |
|---|---|
| `ui/Protocols/wayland.xml`, `ui/Protocols/xdg-shell.xml` | The protocol descriptions of Wayland and of xdg-shell |
| `ui/Sources/CXDGShellClient/` | The C code that `wayland-scanner` makes from `xdg-shell.xml` |

These files are under the MIT license and they keep their copyright notices. The MIT license and the Apache License 2.0 work together, so they put no condition on the rest of Apus.

`ui/Sources/Wayland/Protocols/` holds Swift code that `make protocols` makes from the same two XML files.

## The disk image

`out/live.img` is not one program. It is a collection of 184 packages. Most of them come from Arch Linux ARM, and four come from `packages/`. Each package keeps the license that its authors gave it, and many of those licenses are the GPL.

This does not change the license of Apus, and the license of Apus does not change them. A distribution is a collection of separate programs. The Apache License 2.0 applies to the code in this repository, and each package in the image applies its own license to itself.

## If you publish an image

The GPL asks for one thing: a person who receives a GPL program as a binary can get the source of that program.

The image holds GPL programs, for example the kernel, systemd, bash and pacman. Therefore, do these four things when you publish an image:

1. Publish `out/packages.lock` with the image. It names the exact version of each package, so a person can find the source that goes with the binary.
2. Point to the build files of Arch Linux ARM at <https://github.com/archlinuxarm/PKGBUILDs>, and to the build files of Arch Linux at <https://gitlab.archlinux.org/archlinux/packaging>. The packages in the image come from there, and Apus does not change them.
3. Point to this repository for the four packages that it builds. `packages/apus-zink/no-null-descriptor.py` is the one change that Apus makes to a program of another project, and it is in the repository.
4. Keep the source available for as long as you offer the image. A written offer of source under the GPL version 2 must be good for three years.

A stricter reading of the GPL asks you to keep the source yourself, and not only to point at the server of another project. Upstream projects remove old versions after some time. To be safe, keep a copy of the source packages of each image that you publish.

This file is a summary, and it is not legal advice.
