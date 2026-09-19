// swift-tools-version: 6.4
//
// mydistro's user interface, written in Swift.
//
// The C libraries below are the only non-Swift layer: they are how any Linux
// display server talks to the kernel (DRM/KMS, input devices) and to apps
// (Wayland), plus font rasterisation and shaping. Everything above them —
// compositor, window management, shell, toolkit — is meant to be Swift.

import PackageDescription

// A C library found with pkg-config, wrapped as a Swift module
// (Sources/<name>/module.modulemap + shim.h). `package` is the Arch Linux
// package that provides it (a dependency of the mydistro-ui package).
func system(_ name: String, pkgConfig: String, package: String) -> Target {
    .systemLibrary(name: name, pkgConfig: pkgConfig)
}

let package = Package(
    name: "mydistro-ui",
    products: [
        .library(name: "DRM", targets: ["DRM"]),
        .executable(name: "mydistro-display-probe", targets: ["DisplayProbe"]),
        .executable(name: "mydistro-ui-check", targets: ["UICheck"]),
    ],
    targets: [
        // Display: kernel mode setting and buffers.
        system("CDRM", pkgConfig: "libdrm", package: "libdrm"),
        system("CGBM", pkgConfig: "gbm", package: "mesa"),
        // GPU rendering (Mesa; software rendering in the QEMU VM).
        system("CEGL", pkgConfig: "egl", package: "mesa"),
        system("CGLES", pkgConfig: "glesv2", package: "mesa"),
        // Input: devices, hotplug, keymaps, and seat (device access) management.
        system("CInput", pkgConfig: "libinput", package: "libinput"),
        system("CUdev", pkgConfig: "libudev", package: "systemd-libs"),
        system("CXKBCommon", pkgConfig: "xkbcommon", package: "libxkbcommon"),
        system("CSeat", pkgConfig: "libseat", package: "seatd"),
        // The Wayland protocol, for the compositor and for apps.
        system("CWaylandServer", pkgConfig: "wayland-server", package: "wayland"),
        system("CWaylandClient", pkgConfig: "wayland-client", package: "wayland"),
        // Text: glyph rasterisation and shaping.
        system("CFreeType", pkgConfig: "freetype2", package: "freetype2"),
        system("CHarfBuzz", pkgConfig: "harfbuzz", package: "harfbuzz"),

        // Swift layer over DRM/KMS: find outputs, allocate buffers, show them.
        .target(name: "DRM", dependencies: ["CDRM"]),

        // Takes over the screen and draws a test pattern (used by tests/display.exp).
        .executableTarget(name: "DisplayProbe", dependencies: ["DRM"]),

        // Links against every C library above and exercises each one briefly:
        // proves the toolchain, the module maps and the target's runtime libraries.
        .executableTarget(name: "UICheck", dependencies: [
            "CDRM", "CGBM", "CEGL", "CGLES", "CInput", "CUdev", "CXKBCommon", "CSeat",
            "CWaylandServer", "CWaylandClient", "CFreeType", "CHarfBuzz",
        ]),
    ]
)
