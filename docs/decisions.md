# Decisions

This file records the main decisions, the reasons, and the evidence. Dates are in 2026.

## Build in Apple container, test in QEMU (19 September)

The builder runs in Apple `container`, not Docker. The tests run in QEMU with HVF on the Mac.

- Each Apple container is a small Linux VM on Apple silicon. It runs aarch64 Linux at native speed.
- QEMU with HVF runs aarch64 VMs at near native speed. An x86_64 VM on the Mac is 10 to 50 times slower, because QEMU must emulate the CPU.

## aarch64 only, for now (19 September)

mydistro supports only aarch64. The Mac runs aarch64 VMs fast. Support for x86_64 can come later.

## Buildroot, then Arch Linux ARM (19 September)

The first version used Buildroot 2026.02.3. It built a small system from source in approximately 14 minutes. It is at the git tag `buildroot-v0`.

Then the requirements changed: systemd and a package manager (first yum, then pacman). Buildroot cannot give these:

- Buildroot makes a fixed image. It has no pacman package.
- A package manager needs a repository of packages built against the same libraries. Arch Linux ARM packages do not match the libraries that Buildroot compiles.

Thus, mydistro now uses Arch Linux ARM as its base. `pacstrap` installs the packages. The installer, the image, and the tests stayed.

Arch Linux ARM is a community port with fewer maintainers than Arch Linux. It is a rolling release, and it has no archive of old package versions.

## Omarchy as a model (19 September)

Omarchy is a configuration layer on Arch Linux: packages, settings, and an installer. On Apple silicon, it uses Asahi Linux (kernel and boot chain) and Arch Linux ARM. mydistro follows the same model. In a VM, mydistro needs no Asahi parts. Asahi can come later for real Mac hardware.

Approximately 123 of 148 packages in the Omarchy base list are in Arch Linux ARM. Omarchy M builds the others in its own aarch64 repository.

## Swift 6.4 for the user interface, without wlroots (19 September)

The complete user interface is to be written in Swift: the compositor, the window management, the shell, and the toolkit. Swift uses the kernel-facing C libraries (libdrm, libinput, libseat, Wayland, Mesa, FreeType, HarfBuzz). It uses no wlroots and no other compositor.

The toolchain is the official Fedora 41 build of Swift 6.4.0. Swift has no Arch Linux build. The Fedora build works with a few links. The programs link the Swift runtime statically, so target systems do not need Swift.

## OpenSwiftUI: not yet (19 September)

OpenSwiftUI was the choice for the UI layer. A test with OpenSwiftUI 0.21.0 on Linux gave these results:

| Test | Result |
|---|---|
| Default view graph (OpenAttributeGraph) | Compiles in approximately 1 minute. Stops with a segmentation fault at start, in `GraphHost.Data.updateSeed`. |
| `Compute` view graph | Does not compile on Linux. Compute supports only Apple platforms. |
| `DanceUIGraph` view graph | Only a binary for Apple platforms. |

Also, on Linux:

- The only renderer writes text to standard output. The `CGTK` module has no code that uses it.
- There is no text layout.
- The app runner draws one time and stops. It has no event loop.

The OpenSwiftUI documentation gives Linux 2 of 5 stars.

Decision: build the compositor in Swift now. The compositor makes a display list for each frame. A UI layer can add items to the display list later. Test OpenSwiftUI again with each new release.

## Software rendering in the VM (19 September)

QEMU from Homebrew has no `virtio-gpu-gl`. The compositor renders with the CPU, and Mesa uses llvmpipe. Screenshots are the same each time, and this makes the tests reliable. UTM has a QEMU with GPU acceleration, if it becomes necessary.

## Compile the UI on the Mac with a Swift SDK (19 September)

`make ui` compiles `ui/` on the Mac with the swift.org toolchain for macOS and a Swift SDK that `make sdk` exports from the builder. Before, `make ui` compiled in the builder container.

- A full build of `ui/` takes approximately 5 seconds on the Mac.
- SourceKit-LSP can use the SDK. Thus, an editor gets code completion for the Linux modules.
- The image build still uses the Linux toolchain in the container. `make test` tests those programs, and `make test-dev` tests the programs from the Mac. Both pass.

The SDK comes from the builder image, not from the image of mydistro. The image does not have the files for the linker (for example `crtbegin.o` and the `libstdc++.so` link). The builder has the same packages from the same repositories.

## Xcode as a front end, not as the build system (19 September)

Xcode builds only for Apple platforms, and it cannot use a Swift SDK. Thus, `mydistro.xcodeproj` has external build targets that run make. Cmd-B runs the build, and Xcode puts the compiler errors in the source. Xcode cannot give code completion for the Linux modules. An `.xcworkspace` gives nothing more than the project, so there is none.

## A Wayland server in Swift, not libwayland-server (19 September)

The `Wayland` library replaces libwayland-server. The reasons:

- The C shims for libwayland-server are gone. They had helpers for names that C uses two times, a helper for a variadic function, and a `container_of` structure. The generated C code for xdg-shell in the compositor is also gone.
- `ui/` now has approximately 20 lines of C headers for the compositor.
- A request is a Swift enum case with typed arguments, and an event is a method with typed arguments. Before, the handlers were C function tables with `Unmanaged` pointers.
- The code generator is Swift (`ui/Tools/WaylandScanner`). It runs on the Mac.

The compositor test uses `mydistro-hello-client`, which uses libwayland-client. Thus, the test checks the Swift server against the C implementation of the protocol.

libwayland-client stays for the test client, because most apps use it.

## Embedded Swift: no (19 September)

Embedded Swift is a subset of Swift for microcontrollers and kernels. It does not remove the need for C libraries such as libinput or Mesa. It removes runtime metadata, reflection, and most existential types. The programs already link the Swift runtime statically. The only gain is smaller programs. A fully static program (with the Swift Static Linux SDK and musl) needs static builds of libinput, libudev, and Mesa. Arch Linux does not supply these, and Mesa loads its GPU drivers at run time.

## Documentation style

The documentation uses ASD-STE100 Simplified Technical English, in the STE-flavored mode.
