# User interface (Swift)

The plan is to write the complete user interface in Swift 6.4: the compositor, the window management, the shell, and the toolkit. The code is a Swift package in `ui/`. It uses no wlroots and no other compositor or toolkit.

## The Swift toolchain

The builder image has the official Swift 6.4.0 toolchain for Fedora 41 (aarch64) in `/opt/swift`. Swift has no official build for Arch Linux. The Fedora build works on Arch Linux with these changes in the builder image:

| Library that Swift needs | Arch Linux has | Change |
|---|---|---|
| `libncurses.so.6`, `libform.so.6`, `libpanel.so.6` | Only the wide-character versions (`...w.so.6`, same ABI) | Links to the `w` versions |
| `libxml2.so.2` | `libxml2.so.16` | Install `libxml2-legacy` |
| `libpython3.13.so` (only for `lldb`) | Python 3.14 | None. `lldb` does not work in the builder. |

The target system does not need these changes. The build links the Swift runtime statically (`--static-swift-stdlib`), so the programs need only glibc, libstdc++, and the C libraries below.

Your Mac can edit the code, but Xcode and SourceKit on macOS cannot find the Linux C libraries. Errors such as `No such module 'CDRM'` in the editor are normal. The builder container compiles the code.

## The package

| Target | Kind | Content |
|---|---|---|
| `CDRM`, `CGBM`, `CEGL`, `CGLES`, `CInput`, `CUdev`, `CXKBCommon`, `CSeat`, `CWaylandServer`, `CWaylandClient`, `CFreeType`, `CHarfBuzz` | System library | The C libraries, found with pkg-config |
| `CXDGShellServer`, `CXDGShellClient` | C | The `xdg-shell` protocol code that `wayland-scanner` makes |
| `DRM` | Swift library | A Swift layer over libdrm |
| `Compositor` | Swift library | The compositor. See [compositor.md](compositor.md). |
| `mydistro-compositor` | Program | Runs the compositor |
| `mydistro-hello-client` | Program | A small Wayland app with one window |
| `mydistro-display-probe` | Program | Draws a test pattern on the screen, then restores the screen |
| `mydistro-ui-check` | Program | Calls each C library once. It needs no display. |

### The C library modules

| Purpose | C library | Module |
|---|---|---|
| Display modes and buffers (DRM/KMS) | libdrm, GBM | `CDRM`, `CGBM` |
| GPU rendering | EGL, OpenGL ES (Mesa) | `CEGL`, `CGLES` |
| Input devices and hotplug | libinput, libudev | `CInput`, `CUdev` |
| Keymaps | xkbcommon | `CXKBCommon` |
| Device access for a session | libseat | `CSeat` |
| Protocol between the compositor and apps | Wayland | `CWaylandServer`, `CWaylandClient` |
| Glyphs and text shaping | FreeType, HarfBuzz | `CFreeType`, `CHarfBuzz` |

Each module is a directory in `ui/Sources/` with a `module.modulemap` and a `shim.h`. The `shim.h` file includes the C headers. Some shims also add small C helpers, because Swift cannot use some C constructs directly:

| C construct | Problem in Swift | Helper |
|---|---|---|
| Macros such as `DRM_FORMAT_XRGB8888` | Swift does not import function-like macros | Constants such as `CDRM_FORMAT_XRGB8888` |
| `struct wl_surface_interface` and the variable `wl_surface_interface` | C uses one name for two things | `wl_surface_interface_ptr()` for the variable, `wl_surface_requests` for the struct |
| `wl_registry_bind(..., &wl_compositor_interface, ...)` | Swift cannot get the address of a C constant | `wl_compositor_interface_ptr()` |
| `wl_resource_post_error(...)` | Swift cannot call variadic C functions | `wl_resource_post_error_message()` |
| `container_of()` with `wl_listener` | Swift has no `container_of` | `struct swift_wl_listener` with a context pointer |

### Wayland protocol code

`wayland-scanner` makes C code from the protocol XML files. The script `ui/Scripts/generate-protocols.sh` runs it. `make protocols` runs the script in the builder container.

The generated files are in git. For each protocol, there are two targets: `<Name>Server` for the compositor and `<Name>Client` for apps. Both contain the interface definitions, because no program links both. `ui/Sources/GENERATED_PROTOCOLS` records the wayland-protocols version.

To add a protocol, add a `gen` line to the script, run `make protocols`, and add the two targets to `Package.swift`.

## The tools

`mydistro-ui-check` calls each C library once. It prints one line for each library, then `UI-CHECK-OK`. It makes a Wayland display, a libinput context, and a keymap, and it gets the FreeType and HarfBuzz versions.

`mydistro-display-probe [--hold SECONDS]` does these steps:

1. It finds the first DRM device with a connected output.
2. It fills a framebuffer with mydistro purple (`#965ADC`) and a white rectangle over the middle half of the screen.
3. It puts the framebuffer on the screen, waits, and restores the screen.

It must run as root, when no other program uses the display.

## Development loop

1. Edit the Swift code in `ui/`.
2. Run `make ui`. It compiles in the builder container in a few seconds and copies the programs to `out/ui/`.
3. Run `make gui` or `make installed`, and log in as `root`.
4. Run the new build from the shared directory, for example `/mnt/host/ui/mydistro-compositor`.

`make ui` makes a debug build. It does not change the image. To put the UI in the image, run `make build`. The build keeps the Swift build cache in the `mydistro-work` volume, so it compiles only the changed files.

`make ui` uses the build cache `/work/swiftpm/dev`. The image build uses `/work/swiftpm/mydistro-ui`.

## Graphics in the VM

QEMU from Homebrew has no GPU acceleration (`virtio-gpu-gl`). The VM has a virtio-gpu display without 3D. Mesa renders with the CPU (llvmpipe), and the compositor renders with the CPU. UTM includes a QEMU with GPU acceleration.
