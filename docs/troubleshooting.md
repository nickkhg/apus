# Troubleshooting

This file lists the problems that occurred during the development of Apus, and their solutions.

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

Solution: the `apus-ui` `PKGBUILD` has `options=('!strip')`, and the linker removes the symbols (`-Xlinker --strip-all`).

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

Symptom: with `LIBSEAT_BACKEND=noop`, `apus-compositor` stops at start. `APUS_DEBUG=1` shows only "opening seat".

Cause: the libseat `noop` backend enables the seat in `libseat_dispatch()`. Then it waits forever if the timeout is -1.

Solution: the compositor calls `libseat_dispatch()` with the timeout 0, and waits on the seat file descriptor itself.

## The compositor: libseat cannot open a seat

Symptom: `libseat can't open a seat`.

Cause: the session has no seat. This occurs on the serial console.

Solution: as root, set `LIBSEAT_BACKEND=noop`. The shell of an installed system needs none of this: `apus-shell.service` starts seatd, and libseat takes the seat from it. See [compositor.md](compositor.md#it-starts-the-machine).

## libinput: "Assertion `interface->open_restricted != NULL' failed"

Cause: libinput needs the callbacks `open_restricted` and `close_restricted`, also when no device is open.

Solution: give the callbacks. The compositor opens the devices through libseat.

## Swift compiler: "failed to produce diagnostic for expression"

Cause: the compiler does not show the real error. Two causes occurred:

- A function type that does not match the C function.
- `wl_resource` is a complete struct in the libwayland headers. Thus, Swift uses `UnsafeMutablePointer<wl_resource>`, not `OpaquePointer`.

Solution: correct the types. The compositor uses `typealias Resource = UnsafeMutablePointer<wl_resource>`.

## Editor: "No such module 'CDRM'" or "No such module 'Glibc'"

Cause: the editor compiles for macOS. The Linux modules are only in the Apus Swift SDK.

Solution: in Xcode, none is possible. Xcode cannot use a Swift SDK. The build (`make ui`) is correct. In an editor that uses SourceKit-LSP, use the toolchain in `build/cache/swift-6.4.0-macos/`. See [ui.md](ui.md#code-completion-in-other-editors).

## ld.lld: "undefined symbol: drmAvailable"

Symptom: `make ui` fails to link, but `make ui-container` links.

Cause: macOS file systems ignore the case of letters in file names. The Swift library target `DRM` made `libDRM.a`. The linker looked for `libdrm.so` and found `libDRM.a` first.

Solution: the target has the name `DRMKit`. Do not give a Swift target the name of a C library. After a rename, remove `ui/.build`, because the old file stays there.

## make ui: headers or libraries from Homebrew

Symptom: without the pkg-config settings, the build used `/opt/homebrew/include/freetype2` and linked to `/opt/homebrew/opt/freetype/lib`.

Cause: SwiftPM runs pkg-config on the Mac. pkg-config finds the macOS libraries of Homebrew.

Solution: `Package.swift` uses pkg-config only on Linux. On the Mac, the SDK gives the include directories, and each module map gives its library.

## Xcode: "Internal inconsistency error: never received target ended message"

Symptom: this message comes after each failed build in Xcode 27.

Cause: Xcode 27 shows it when an external build target fails. An external build target that only runs `exit 1` gives the same message.

Solution: none is necessary. Look at the other errors.

## Xcode: compiler errors do not go to the source line

Cause: the Swift build prints colour codes. Xcode finds `file:line:column: error:` only in plain text.

Solution: `xcode/make.sh` removes the colour codes.

## A build from Xcode stops, and the container service is not running

Symptom: a build from Xcode stops with a message about a connection. The same build works in a terminal, after `container system start`.

Cause: Apple's `container` runs the build in a Linux VM, and a background service holds that VM. The first start of the service asks a question, and only a person can answer it. Therefore the build does not start the service itself.

Solution: run `container system start` in a terminal one time. `make` now examines the service first and says this, instead of stopping with a message about a connection.

## A clone on a second Mac does not build apus-vm

Symptom: `cannot find 'VirglRenderer' in scope`, approximately 26 times, in `VirtioGPUDevice.swift`.

Cause: `VirglRenderer.swift` is inside `#if VIRGL`, and the Makefile defines `VIRGL` only when `build/cache` holds a build of virglrenderer. The device calls the renderer inside `renderer { ... }`, which is empty without `VIRGL`. This looked safe, but it is not: the compiler reads the body of a closure before it knows who calls it. The first Mac always had the renderer, so no build found this.

Solution: two changes. `make vm` now builds the renderer, and the script installs what the build of the renderer needs. `vm/Sources/apus-vm/VirglRendererMissing.swift` gives the names that the closures ask for when a Mac cannot build the renderer.

## "VM exited before login" on a machine that never installed a disk

Symptom: `make demo`, `make demo-dev` or `make gui` stops with `TEST FAILED: VM exited before login`. The log before it shows a machine that starts, shows two screen sizes, and stops.

Cause: those targets boot `out/vm/target.img`, which is the disk that the installer wrote. `tests/install.exp` writes it, and `make test` runs that test. A clone has no such disk. The machine then starts, the firmware finds nothing to boot, and the machine stops.

Solution: `make` now installs the disk when there is none, so these targets work from a clone. `make install-disk` does only that step. The first run takes some minutes, because it builds the image and then installs it.

## apus-vm stops in Metal: "bytesPerRow must be a multiple of pixel bytes"

Symptom: from Xcode, `make demo-dev` or `make gui` stops with

```
_validateReplaceRegion:252: failed assertion `Replace Region Validation
bytesPerRow(6619) must be a multiple of MTLPixelFormatBGRA8Unorm pixel bytes(4).
```

and then `expect: spawn id exp5 not open`, because the machine is gone. The same command in a terminal works.

Cause: two things together.

1. Zink binds memory to an image, and MoltenVK writes that memory into a Metal texture. MoltenVK computes the length of a row, and the number it computes is not a whole count of pixels. The number follows the size of the screen: 6619 on a screen of one size, 13238 on a screen of two times the pixels.
2. Xcode turns Metal API Validation on for the programs that it runs, with `METAL_DEVICE_WRAPPER_TYPE`. A child of `make` keeps the variable. Validation stops the program at the row above, where Metal alone accepts it.

The frames are correct. A picture of the shell in GPU mode, through Venus, shows the rail, the glow, the clock and the text, with nothing out of place.

Solution: `apus-vm` takes the validation switches out of itself, before it makes a Metal device. See `vm/Sources/apus-vm/MetalValidation.swift`. The Makefile also takes `METAL_DEVICE_WRAPPER_TYPE` away from the machine (`unexport`). That alone was not sufficient. A build from Xcode stopped here again, because Xcode turns validation on with a name that the Makefile does not know.

Therefore the program says what it did:

```
apus-vm: Metal validation off for this machine: METAL_DEVICE_WRAPPER_TYPE MTL_DEBUG_LAYER
apus-vm: Metal names that this program leaves alone: ...
```

The second line names every other `MTL_` and `METAL_` name in the environment. A Mac that stops here again names the switch that the list does not have, so the next step is not a guess. The program leaves those names alone. A name that no test examined is not a name to take away in silence.

Xcode has the same switch in the scheme: Product, Edit Scheme, Run, Diagnostics, Metal API Validation. Turning it off there stops the fault as well. The program does not need it: it takes the switches out of itself, whatever starts it.

`APUS_METAL_VALIDATION=1` keeps validation on, to look at this again.

`tests/venus.exp` now draws the shell in its GPU mode as well. Before, every step of it pinned `APUS_SHELL_MODE=cpu`, so the shadow, the blur and the gradient never went through Venus in any test.
