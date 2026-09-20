// swift-tools-version: 6.4
//
// The mydistro toolkit: the declarative user interface layer, and the shell
// that mydistro draws with it.
//
// This package builds for two systems:
//
//   mydistro (aarch64 Linux)   `make ui` cross-compiles it with the mydistro
//                              Swift SDK, together with the display server.
//   macOS                      `make test-ui` builds and tests it on the Mac
//                              in seconds. Xcode gives code completion.
//
// Only the text code is platform-dependent, and only in two places: which
// header directory FreeType and HarfBuzz are in, and where the font files
// are. See Sources/Toolkit/FontCache.swift.

import Foundation
import PackageDescription

// `make ui` sets MYDISTRO_CROSS. Then the build uses the mydistro Swift SDK,
// which supplies the include directories, and pkg-config must not run: on the
// Mac it would answer with the macOS libraries of Homebrew.
let cross = ProcessInfo.processInfo.environment["MYDISTRO_CROSS"] == "1"

func system(_ name: String, pkgConfig: String) -> Target {
    cross ? .systemLibrary(name: name) : .systemLibrary(name: name, pkgConfig: pkgConfig)
}

let package = Package(
    name: "mydistro-toolkit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Render", targets: ["Render"]),
        .library(name: "Toolkit", targets: ["Toolkit"]),
        .library(name: "Shell", targets: ["Shell"]),
        // The display server links these C libraries too (mydistro-ui-check).
        .library(name: "CFreeType", targets: ["CFreeType"]),
        .library(name: "CHarfBuzz", targets: ["CHarfBuzz"]),
    ],
    targets: [
        // Text: glyph rasterisation and shaping.
        system("CFreeType", pkgConfig: "freetype2"),
        system("CHarfBuzz", pkgConfig: "harfbuzz"),

        // What to draw (the display list) and how to draw it (the CPU
        // renderer). The bottom of the UI stack.
        .target(name: "Render"),

        // The views, the layout and the text. It makes display lists, so it
        // knows nothing about the screen, the windows or Wayland.
        .target(name: "Toolkit", dependencies: ["Render", "CFreeType", "CHarfBuzz"]),

        // The user interface of mydistro itself: RootView and what is in it.
        // Write your UI here.
        .target(name: "Shell", dependencies: ["Toolkit", "Render"]),

        // How long a frame takes: swift run -c release toolkit-bench
        .executableTarget(name: "toolkit-bench", dependencies: ["Shell", "Toolkit", "Render"]),

        .testTarget(name: "ToolkitTests", dependencies: ["Toolkit", "Render"]),
        .testTarget(name: "ShellTests", dependencies: ["Shell", "Toolkit", "Render"]),
    ]
)
