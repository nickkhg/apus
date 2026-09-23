# Decisions

This file records the main decisions, the reasons, and the evidence. Dates are in 2026.

## Build in Apple container, test in QEMU (19 September)

The builder runs in Apple `container`, not Docker. The tests run in QEMU with HVF on the Mac.

- Each Apple container is a small Linux VM on Apple silicon. It runs aarch64 Linux at native speed.
- QEMU with HVF runs aarch64 VMs at near native speed. An x86_64 VM on the Mac is 10 to 50 times slower, because QEMU must emulate the CPU.

## Apple's Virtualization framework, not QEMU (20 September)

The tests and the demos run in a VM that Apple's Virtualization framework makes. `vm/apus-vm` is a Swift program, and it replaces `vm/run.sh` and QEMU.

Reasons:

- The Mac needs no QEMU from Homebrew. The framework is part of macOS, and Xcode gives the Swift toolchain that compiles the program.
- Xcode can start the program and debug it.
- A boot to the login prompt takes approximately 10 seconds.
- The host side of the project is now Swift, like the guest side.

The framework gives a Linux guest no GPU, so this change is not a step towards GPU rendering. See [ui.md](ui.md#graphics-in-the-vm).

The change cost the tests their eyes and their hands on the host. QEMU made pictures of the screen with `screendump`, and it sent input with QMP. The framework does neither. The guest does both now: the compositor writes the buffer that it gave to the display, and `apus-screen` makes a pointer and a keyboard with uinput. The pictures reach the Mac through a writable virtiofs share. Input still goes through evdev, libinput and xkbcommon, so the tests cover the same code as before. See [testing.md](testing.md#screenshots).

Other differences:

| QEMU | Virtualization |
|---|---|
| qcow2 disks | Raw disks only. The target disk is a sparse file. |
| `snapshot=on` keeps the live image unchanged | A copy of the live image for each boot. On APFS the copy is a clone, and it is immediate. |
| 9p for `/mnt/host` | virtiofs |
| `ConditionVirtualization=qemu` | `ConditionVirtualization=apple` |
| edk2 firmware from Homebrew | The EFI firmware of the framework |

The program needs the entitlement `com.apple.security.virtualization`. Without it, the framework refuses to make a VM. A local (ad hoc) signature carries the entitlement, and `make vm` signs the program.

## aarch64 only, for now (19 September)

Apus supports only aarch64. The Mac runs aarch64 VMs fast. Support for x86_64 can come later.

## Buildroot, then Arch Linux ARM (19 September)

The first version used Buildroot 2026.02.3. It built a small system from source in approximately 14 minutes. It is at the git tag `buildroot-v0`.

Then the requirements changed: systemd and a package manager (first yum, then pacman). Buildroot cannot give these:

- Buildroot makes a fixed image. It has no pacman package.
- A package manager needs a repository of packages built against the same libraries. Arch Linux ARM packages do not match the libraries that Buildroot compiles.

Thus, Apus now uses Arch Linux ARM as its base. `pacstrap` installs the packages. The installer, the image, and the tests stayed.

Arch Linux ARM is a community port with fewer maintainers than Arch Linux. It is a rolling release, and it has no archive of old package versions.

## Omarchy as a model (19 September)

Omarchy is a configuration layer on Arch Linux: packages, settings, and an installer. On Apple silicon, it uses Asahi Linux (kernel and boot chain) and Arch Linux ARM. Apus follows the same model. In a VM, Apus needs no Asahi parts. Asahi can come later for real Mac hardware.

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

Decision: build the compositor in Swift now. The compositor makes a display list for each frame. A UI layer can add items to the display list later.

## A toolkit of our own, not OpenSwiftUI (20 September)

A second test of OpenSwiftUI, at commit `5af2b2b` (newer than release 0.21.0), gave the same segmentation fault in `GraphHost.Data.updateSeed`. This time we found the cause. In OpenAttributeGraph, all 29 attribute operations in `OAGAttribute.cpp` are `// TODO`. `OAGGraphCreateAttribute` gives a null attribute, and `OAGGraphGetValue` gives a null pointer. The functions that add inputs, update values and invalidate values do nothing. The C++ that is complete is the type and metadata layer around the engine, not the engine.

Thus OpenSwiftUI on Linux does not need a correction. It needs a new attribute graph: a demand-driven dependency engine with attribute bodies of any type, subgraphs and invalidation. After that work, OpenSwiftUI on Linux still has no text layout and no event loop.

Apus needs a panel, window title bars and a settings UI. It does not need all of SwiftUI. Decision: write the toolkit in this repository. It keeps the API shape of SwiftUI (`View`, `body`, `VStack`, `Text`, `.padding`). It lowers the views to the display list for each frame. The first version is approximately 1300 lines, and 40 unit tests cover it. See [toolkit.md](toolkit.md).

An incremental dependency graph saves work in a large app. A shell is small, so the first version worked the whole tree out for every frame.

**21 September:** the toolkit has that graph now. A move made the cost of a whole frame the cost of each of its frames. Most of that cost was text: every frame drew every line into a new picture. `Graph.swift` holds the model of AttributeGraph, and a view that is the same value keeps what it made. One frame of Summon opening went from 2.41 ms to 0.76 ms, and a frame that nothing moves from 0.24 ms to 0.16 ms. The view API did not change, as this decision said it would not. See [toolkit.md](toolkit.md#the-graph).

## A GPU renderer beside the CPU renderer (20 September)

The compositor can now draw with the GPU: GBM makes the buffers, EGL draws into them, and GLES draws the display list. `APUS_RENDERER=gpu` chooses it. The CPU renderer stays, and it is the default.

Both renderers take the same display list. [Scene.swift](../ui/Toolkit/Sources/Render/Scene.swift) says that from its first line. The compositor, the toolkit and the shell did not change.

The tests keep the CPU renderer. Its pixels are the same on every run, and the tests check exact colours. A GPU rounds its own way, and a different driver would give different pixels. `tests/gpu.exp` runs the GPU renderer and checks only the solid colours, which both renderers must get exactly right.

The two renderers agree to 3 of 255 in a colour channel. The difference is rounding: the CPU divides by 256 (a shift), and the GPU divides by 255.

Filling an outline has no rule on a GPU. The GPU renderer therefore asks `SoftwareRenderer.mask` for the coverage of a path and puts it in a texture. That is the rasterizer of the CPU renderer, so the edges are the same in both. `TextureCache` keeps the masks. The shapes of a shell do not change from frame to frame, so the CPU draws each one time only.

This work does not give the guest a GPU. In a VM, Mesa still renders with the CPU (llvmpipe), because Apple's Virtualization framework offers a Linux guest no 3D. The gain is on real hardware, and the renderer is the piece that every way of giving a guest a GPU needs first.

## A bug in the blend, found by the second renderer (20 September)

The GPU renderer disagreed with the CPU renderer wherever something was partly transparent: the dock, the icons and the edges of the glyphs. The GPU was right.

`SoftwareRenderer.blend` had this line:

```swift
let rb = ((dst & 0xFF00FF) * inverse >> 8) & 0xFF00FF
```

This is the C idiom, and in C it means `((dst & mask) * inverse) >> 8`. In Swift a shift binds tighter than a multiplication, so it means `(dst & mask) * (inverse >> 8)`. `inverse` is `255 - alpha`, so it is always below 256, so `inverse >> 8` is always 0.

Every partly transparent colour therefore covered what was under it instead of blending with it. The dock was darker than it should be. The smooth edge of a shape went to black, and not to the colour behind it. `scale`, a few lines above, has the brackets and was right.

Two renderers that must agree found a bug that one renderer could not. The tests now hold the arithmetic. See `ui/Toolkit/Tests/RenderTests/BlendTests.swift`.

## Software rendering in the VM (19 September)

QEMU from Homebrew has no `virtio-gpu-gl`. The compositor renders with the CPU, and Mesa uses llvmpipe. Screenshots are the same each time, and this makes the tests reliable, so the tests must keep the CPU renderer. On 20 September we found that Apple's Virtualization framework gives a Linux guest no GPU either. See [ui.md](ui.md#graphics-in-the-vm) and [next-steps.md](next-steps.md).

## Compile the UI on the Mac with a Swift SDK (19 September)

`make ui` compiles `ui/` on the Mac with the swift.org toolchain for macOS and a Swift SDK that `make sdk` exports from the builder. Before, `make ui` compiled in the builder container.

- A full build of `ui/` takes approximately 5 seconds on the Mac.
- SourceKit-LSP can use the SDK. Thus, an editor gets code completion for the Linux modules.
- The image build still uses the Linux toolchain in the container. `make test` tests those programs, and `make test-dev` tests the programs from the Mac. Both pass.

The SDK comes from the builder image, not from the image of apus. The image does not have the files for the linker (for example `crtbegin.o` and the `libstdc++.so` link). The builder has the same packages from the same repositories.

## Xcode as a front end, not as the build system (19 September)

Xcode builds only for Apple platforms, and it cannot use a Swift SDK. Thus, `apus.xcodeproj` has external build targets that run make. Cmd-B runs the build, and Xcode puts the compiler errors in the source. Xcode cannot give code completion for the Linux modules. An `.xcworkspace` gives nothing more than the project, so there is none.

## A Wayland server in Swift, not libwayland-server (19 September)

The `Wayland` library replaces libwayland-server. The reasons:

- The C shims for libwayland-server are gone. They had helpers for names that C uses two times, a helper for a variadic function, and a `container_of` structure. The generated C code for xdg-shell in the compositor is also gone.
- `ui/` now has approximately 20 lines of C headers for the compositor.
- A request is a Swift enum case with typed arguments, and an event is a method with typed arguments. Before, the handlers were C function tables with `Unmanaged` pointers.
- The code generator is Swift (`ui/Tools/WaylandScanner`). It runs on the Mac.

The compositor test uses `apus-hello-client`, which uses libwayland-client. Thus, the test checks the Swift server against the C implementation of the protocol.

libwayland-client stays for the test client, because most apps use it.

## Embedded Swift: no (19 September)

Embedded Swift is a subset of Swift for microcontrollers and kernels. It does not remove the need for C libraries such as libinput or Mesa. It removes runtime metadata, reflection, and most existential types. The programs already link the Swift runtime statically. The only gain is smaller programs. A fully static program (with the Swift Static Linux SDK and musl) needs static builds of libinput, libudev, and Mesa. Arch Linux does not supply these, and Mesa loads its GPU drivers at run time.

## PipeWire for sound, as a service of the system (23 September)

The guest plays sound on the speakers of the Mac. PipeWire is the sound
server, with WirePlumber, `pipewire-pulse` and `pipewire-alsa`. See
[audio.md](audio.md).

| Choice | Result |
|---|---|
| ALSA only | One program at a time has the card. A system sound then stops while an app plays, or the app stops. No mixing, and no volume for each stream. |
| PulseAudio | It mixes, but Arch Linux has replaced it with PipeWire. PipeWire speaks its protocol, so its programs work without it. |
| PipeWire | The default of Arch Linux. It mixes, it has a volume for each stream, and it speaks PulseAudio, ALSA and JACK to programs. |

PipeWire runs as three services of the system (`apus-pipewire`,
`apus-wireplumber`, `apus-pipewire-pulse`), not under `systemd --user`. The
shell runs as root, as a service of the system, with no login session, and
the units of the packages refuse root. The shell starts the sound server,
and the server is in `/run/pipewire`, where the shell, its apps and a login
on the console all find it. When the shell runs in the session of a person,
the units of the packages can take this work back.

The Arch Linux ARM kernel has no `virtio_snd`, which is the only sound
device of Apple's Virtualization framework. `packages/virtio-snd` builds
that one module from the kernel release, against `linux-aarch64-headers`.
A kernel of our own was the other way. It is a long build, and a package to
keep up with, for one module.

## Documentation style

The documentation uses ASD-STE100 Simplified Technical English, in the STE-flavored mode.
