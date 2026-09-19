# Troubleshooting

This file lists the problems that occurred during the development of mydistro, and their solutions.

## Containers cannot connect to the internet

Symptom: in a container, DNS works, but all TCP connections stop with a timeout. `pacman`, `curl`, and `git` do not work.

Cause: a Tailscale exit node on the Mac. The default route goes through the Tailscale interface (`utun`). The container network (192.168.64.0/24) does not go through it.

Solution:

1. Examine the default route: `route -n get default`. If the interface is `utun`, a VPN has the default route.
2. Turn off the Tailscale exit node.
3. Restart the container service: `container system stop`, then `container system start`. Step 2 alone is not sufficient.

## pacman fails in the builder

Symptom: `error: switching to sandbox user 'alpm' failed!`, or an error about the free disk space.

Cause: the pacman download sandbox and `CheckSpace` do not work in a container.

Solution: `build/Containerfile` sets `DisableSandbox` and removes `CheckSpace` and `DownloadUser` in the builder only.

## makepkg: "Could not resolve all dependencies"

Cause: `makepkg` checks that the builder has the `depends` packages. These packages are for the target system.

Solution: `build/build.sh` runs `makepkg --nodeps`.

## strip: "bad subsection length"

Cause: GNU `strip` cannot read the Swift binaries that LLVM makes.

Solution: the `mydistro-ui` `PKGBUILD` has `options=('!strip')`, and the linker removes the symbols (`-Xlinker --strip-all`).

## SwiftPM: "Failed to clone repository"

Cause: the builder image had no `git`.

Solution: `build/Containerfile` installs `git`.

## Swift toolchain: "libncurses.so.6: cannot open shared object file"

Cause: swift.org builds the toolchain for Fedora. Arch Linux has only the wide-character ncurses libraries, and it has a newer libxml2.

Solution: `build/Containerfile` adds links and installs `libxml2-legacy`. See [ui.md](ui.md).

## The installed system stops at a question on first boot

Symptom: no login prompt. The last console message is "Started Console Output Muting Service".

Cause: `systemd-firstboot` ("Initial Setup") or `systemd-homed-firstboot` asks questions on the console.

Solution: `build/build.sh` masks the two services and runs `systemctl preset-all`.

## The installed system keeps no changes

Symptom: after each boot, the host name is `archlinux`, the first-boot questions come again, and `/var/log/journal` stays empty. `findmnt /` shows `tmpfs`, and the root partition is on `/usr`.

Cause: `systemd-volatile-root.service` ran on every boot in the default mode `yes`. An earlier version of the `sd-volatile` initramfs hook enabled the service.

Solution: the hook only adds the service to the initramfs. `systemd-fstab-generator` starts it only when the kernel command line has `systemd.volatile=`.

## The installer: "Can't mount, would change RO state"

Cause: systemd mounts the EFI system partition of the live system read-write. A FAT file system cannot have a second mount with different read-only settings.

Solution: the installer mounts the live EFI system partition read-write.

## The compositor does not start, and shows nothing

Symptom: with `LIBSEAT_BACKEND=noop`, `mydistro-compositor` stops at start. `MYDISTRO_DEBUG=1` shows only "opening seat".

Cause: the libseat `noop` backend enables the seat in `libseat_dispatch()`. Then it waits forever if the timeout is -1.

Solution: the compositor calls `libseat_dispatch()` with the timeout 0, and waits on the seat file descriptor itself.

## The compositor: libseat cannot open a seat

Symptom: `libseat can't open a seat`.

Cause: the session has no seat. This occurs on the serial console.

Solution: as root, set `LIBSEAT_BACKEND=noop`. In a login session on a VT (for example tty1 in `make gui`), libseat uses logind.

## libinput: "Assertion `interface->open_restricted != NULL' failed"

Cause: libinput needs the callbacks `open_restricted` and `close_restricted`, also when no device is open.

Solution: give the callbacks. The compositor opens the devices through libseat.

## Swift compiler: "failed to produce diagnostic for expression"

Cause: the compiler does not show the real error. Two causes occurred:

- A function type that does not match the C function.
- `wl_resource` is a complete struct in the libwayland headers. Thus, Swift uses `UnsafeMutablePointer<wl_resource>`, not `OpaquePointer`.

Solution: correct the types. The compositor uses `typealias Resource = UnsafeMutablePointer<wl_resource>`.

## Editor: "No such module 'CDRM'"

Cause: SourceKit on macOS cannot find the Linux C libraries.

Solution: none is necessary. The builder container compiles the code.
