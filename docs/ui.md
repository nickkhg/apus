# User interface (Swift)

The plan is to write the complete user interface in Swift 6.4: the compositor, the window management, the shell, and the toolkit. The code is a Swift package in `ui/`. It uses no wlroots and no other compositor or toolkit.

## Two Swift toolchains

There are two toolchains of the same version, Swift 6.4.0:

| Toolchain | Where | Use |
|---|---|---|
| Linux (Fedora 41 build) | `/opt/swift` in the builder container | The image build (`makepkg`) and `make ui-container` |
| macOS (swift.org build) | `build/cache/swift-6.4.0-macos/` | `make ui`, `make protocols`, and editors |

The macOS toolchain is not the Swift in Xcode. It is the swift.org build, because it includes the linker for Linux (`ld.lld`) and it has the same version as the Linux toolchain. The Makefile downloads the `.pkg` file, checks its SHA-256 value and its signature, and extracts it in `build/cache/`. It does not install the toolchain on the Mac.

### The Linux toolchain in the builder

Swift has no official build for Arch Linux. The Fedora build works on Arch Linux with these changes in the builder image:

| Library that Swift needs | Arch Linux has | Change |
|---|---|---|
| `libncurses.so.6`, `libform.so.6`, `libpanel.so.6` | Only the wide-character versions (`...w.so.6`, same ABI) | Links to the `w` versions |
| `libxml2.so.2` | `libxml2.so.16` | Install `libxml2-legacy` |
| `libpython3.13.so` (only for `lldb`) | Python 3.14 | None. `lldb` does not work in the builder. |

The target system does not need these changes. The build links the Swift runtime statically (`--static-swift-stdlib`), so the programs need only glibc, libstdc++, and the C libraries below.

## The Swift SDK: compile on the Mac

`make sdk` makes the Swift SDK `mydistro-aarch64` in `build/cache/swift-sdks/`. A Swift SDK is a sysroot for a different system. With it, the macOS toolchain compiles `ui/` for mydistro on the Mac, without the container:

```sh
build/cache/swift-6.4.0-macos/usr/bin/swift build --package-path ui \
    --swift-sdks-path build/cache/swift-sdks --swift-sdk mydistro-aarch64
```

`make ui` runs this command (with `--static-swift-stdlib`). A full build takes approximately 5 seconds on the Mac.

`build/make-sdk.sh` makes the SDK in the builder container. The SDK contains:

- The C headers and the libraries of the builder (`/usr/include`, and the `.so`, `.a`, and `.o` files in `/usr/lib`). These are the same packages that the image gets.
- The Swift runtime and modules of the Linux toolchain.
- The include directories that pkg-config gives for the C libraries of `ui/`.

The SDK has approximately 1.1 GB. Run `make sdk` again after a change to the builder image. `make ui` does this automatically.

Two problems apply to a sysroot on macOS:

- macOS file systems ignore the case of letters in file names. The script removes 8 netfilter headers that have the same name as another header in a different case. `ui/` does not use them.
- For the same reason, a Swift library target must not have the name of a C library. The linker found `libDRM.a` (the Swift target `DRM`) when it looked for `libdrm.so`. Thus, the target is `DRMKit`.

## Xcode

Open `mydistro.xcodeproj`. The project has three schemes:

| Scheme | Build (Cmd-B) | Run (Cmd-R) |
|---|---|---|
| UI | `make ui` | `make demo-dev`: boots the installed disk in a window and starts the new build of the compositor and the test client |
| Image | `make build` | `make demo` |
| Tests | `make test` | Nothing |

The targets are "external build system" targets: Xcode runs `xcode/make.sh`, which runs make. Compiler errors appear in the Xcode issue navigator. They go to the correct file and line, because the paths in the messages are paths on the Mac:

- `make ui` compiles on the Mac.
- The builder container mounts the repository at the same path as on the Mac, not at a different path such as `/src`.

Product > Clean does nothing. Use `make clean` in a terminal.

### Limits of Xcode

- Xcode cannot compile for Linux, and it cannot use a Swift SDK. Thus, code completion and jump to definition do not work for the Linux modules in Xcode. Errors such as `No such module 'Glibc'` in the Xcode editor are normal. The build is correct.
- The Xcode debugger cannot attach to a program in the VM.

### Code completion in other editors

`ui/.sourcekit-lsp/config.json` tells SourceKit-LSP to use the mydistro SDK. An editor that uses SourceKit-LSP from `build/cache/swift-6.4.0-macos/usr/bin/sourcekit-lsp` gets code completion, errors, and documentation for all modules, also for the C libraries. For example, use Visual Studio Code with the Swift extension, and set the toolchain path to `build/cache/swift-6.4.0-macos/usr/bin`.

A test with SourceKit-LSP gave the documentation of the C function `libinput_dispatch` and no errors in `Input.swift`.

## The package

| Target | Kind | Content |
|---|---|---|
| `CDRM`, `CGBM`, `CEGL`, `CGLES`, `CInput`, `CUdev`, `CXKBCommon`, `CSeat`, `CWaylandClient`, `CFreeType`, `CHarfBuzz` | System library | The C libraries |
| `CLinux` | System library | The glibc headers for epoll and signalfd. No library and no C code. |
| `CXDGShellClient` | C | The `xdg-shell` client code that `wayland-scanner` makes, for the test client |
| `DRMKit` | Swift library | A Swift layer over libdrm |
| `Wayland` | Swift library | The Wayland server. See [compositor.md](compositor.md). |
| `Render` | Swift library | The display list and the software renderer |
| `Toolkit` | Swift library | The views, the layout, and the text. See [toolkit.md](toolkit.md). |
| `Shell` | Swift library | What mydistro draws itself, as views. Now: the panel. |
| `Compositor` | Swift library | The compositor. See [compositor.md](compositor.md). |
| `mydistro-compositor` | Program | Runs the compositor |
| `mydistro-hello-client` | Program | A small Wayland app with one window. It uses libwayland-client, as most apps do. |
| `mydistro-display-probe` | Program | Draws a test pattern on the screen, then restores the screen |
| `mydistro-ui-check` | Program | Calls each C library once. It needs no screen. |

### The C library modules

| Purpose | C library | Module |
|---|---|---|
| Display modes and buffers (DRM/KMS) | libdrm, GBM | `CDRM`, `CGBM` |
| GPU rendering | EGL, OpenGL ES (Mesa) | `CEGL`, `CGLES` |
| Input devices and hotplug | libinput, libudev | `CInput`, `CUdev` |
| Keymaps | xkbcommon | `CXKBCommon` |
| Device access for a session | libseat | `CSeat` |
| Wayland for apps (the test client only) | libwayland-client | `CWaylandClient` |
| Glyphs and text shaping | FreeType, HarfBuzz | `CFreeType`, `CHarfBuzz` |

The compositor does not use libwayland. Its Wayland server is Swift.

Each module is a directory in `ui/Sources/` with a `module.modulemap` and a `shim.h`. The `shim.h` file includes the C headers. The module map gives the library to link. On Linux, pkg-config gives the compiler flags. On the Mac, `Package.swift` does not use pkg-config, because pkg-config finds the macOS libraries from Homebrew. There, the SDK gives the include directories.

Some shims also add small C helpers, because Swift cannot use some C constructs directly:

| C construct | Problem in Swift | Helper |
|---|---|---|
| Macros such as `DRM_FORMAT_XRGB8888` | Swift does not import function-like macros | Constants such as `CDRM_FORMAT_XRGB8888` |
| `wl_registry_bind(..., &wl_compositor_interface, ...)` | Swift cannot get the address of a C constant | `wl_compositor_interface_ptr()` |

### Wayland protocol code

There are two generators:

| Generator | Output | For |
|---|---|---|
| `ui/Tools/WaylandScanner` (Swift, runs on the Mac) | `ui/Sources/Wayland/Protocols/*.swift` | The compositor |
| `wayland-scanner` (C, runs in the builder) | `ui/Sources/CXDGShellClient/` | The test client |

`make protocols` runs both. It also copies the protocol XML files from the builder to `ui/Protocols/`. The generated files and the XML files are in git. `ui/Sources/GENERATED_PROTOCOLS` records the versions of wayland and wayland-protocols.

To add a protocol to the compositor:

1. Copy its XML file into `ui/Protocols/`. For a file from wayland-protocols, add it to the `cp` line in `ui/Scripts/generate-protocols.sh`.
2. Add a `$(WAYLAND_SCANNER)` line for it to the `protocols` target in the Makefile.
3. Run `make protocols`.

## The tools

`mydistro-ui-check` calls each C library once. It prints one line for each library, then `UI-CHECK-OK`. It makes a libinput context and a keymap, and it gets the FreeType and HarfBuzz versions.

`mydistro-display-probe [--hold SECONDS]` does these steps:

1. It finds the first DRM device with a connected output.
2. It fills a framebuffer with mydistro purple (`#965ADC`) and a white rectangle over the middle half of the screen.
3. It puts the framebuffer on the screen, waits, and restores the screen.

It must run as root, when no other program uses the display.

## Tests

`make test-ui` runs the unit tests of `ui/` in the builder container, with the Linux toolchain. They test the layout, the text, and the panel. They need no screen and no VM, and they take approximately one second. See [toolkit.md](toolkit.md#tests).

The tests that need a screen run in the VM. See [testing.md](testing.md).

## Development loop

1. Edit the Swift code in `ui/`.
2. Run `make ui`, or build the UI scheme in Xcode. The programs go to `out/ui/`.
3. Run `make demo-dev`, or run the UI scheme in Xcode. The VM starts the new programs from `/mnt/host/ui/`.

To test the new programs automatically, run `make test-dev`. It runs the compositor test with the programs from `out/ui/`.

`make ui` makes a debug build. It does not change the image. To put the UI in the image, run `make build`. The image build compiles `ui/` again with the Linux toolchain in the container. It keeps the Swift build cache in the `mydistro-work` volume, so it compiles only the changed files.

`make ui-container` does the same as `make ui` in the builder container, with the cache `/work/swiftpm/dev`.

## Graphics in the VM

QEMU from Homebrew has no GPU acceleration (`virtio-gpu-gl`). The VM has a virtio-gpu display without 3D. Mesa renders with the CPU (llvmpipe), and the compositor renders with the CPU. UTM includes a QEMU with GPU acceleration.
