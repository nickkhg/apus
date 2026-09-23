// swift-tools-version: 6.4
//
// The Apus toolkit: the declarative user interface layer, and the shell
// that Apus draws with it.
//
// This package builds for two systems:
//
//   Apus (aarch64 Linux)   `make ui` cross-compiles it with the Apus
//                              Swift SDK, together with the display server.
//   macOS                      `make test-ui` builds and tests it on the Mac
//                              in seconds. Xcode gives code completion.
//
// Only the text code is platform-dependent, and only in two places: which
// header directory FreeType and HarfBuzz are in, and where the font files
// are. See Sources/Toolkit/FontCache.swift.

import Foundation
import PackageDescription

// `make ui` sets APUS_CROSS. Then the build uses the Apus Swift SDK,
// which supplies the include directories, and pkg-config must not run: on the
// Mac it would answer with the macOS libraries of Homebrew.
let cross = ProcessInfo.processInfo.environment["APUS_CROSS"] == "1"

func system(_ name: String, pkgConfig: String) -> Target {
    cross ? .systemLibrary(name: name) : .systemLibrary(name: name, pkgConfig: pkgConfig)
}

let package = Package(
    name: "apus-toolkit",
    platforms: [.macOS(.v26)],
    // One dynamic library holds the whole user interface stack: Apus
    // carries one copy of it, in /usr/lib, and every program on the machine
    // draws with that copy. A change to the toolkit is then a new library
    // and not a new build of each app.
    //
    // It is one product and not four, because a target cannot be linked
    // into a dynamic library and be a dynamic library. The modules inside
    // it keep their names: a program still writes `import Toolkit`.
    //
    // This works because one build makes the whole system. Swift on Linux
    // has no stable ABI without library evolution, so a library and the
    // programs that use it must come from one build. See docs/ui.md.
    products: [
        .library(name: "ApusUI", type: .dynamic,
                 targets: ["Render", "Toolkit", "Shell", "Terminal", "Settings", "Files", "Notes", "Power"]),
        // The display server links these C libraries too (apus-ui-check).
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

        // The user interface of Apus itself: RootView and what is in it.
        // Write your UI here.
        .target(name: "Shell", dependencies: ["Toolkit", "Render"]),

        // What the terminal app shows: the grid of characters, and the
        // sequences that a program writes to change it. The app itself (the
        // window and the shell in it) is Sources/TerminalApp of the ui
        // package. The part here has no system in it, so its tests run on
        // the Mac.
        .target(name: "Terminal", dependencies: ["Toolkit", "Render"]),

        // What the Settings app draws, and what it makes of the files of the
        // system: the panes, the keys, and the parsers. The app around it,
        // which reads and writes the files, is ui/Sources/SettingsApp.
        .target(name: "Settings", dependencies: ["Toolkit", "Render"]),

        // What the Files app draws: the places, the way to a folder, and
        // the list of what is in it. The app around it, which reads the
        // folders, is ui/Sources/FilesApp.
        .target(name: "Files", dependencies: ["Toolkit", "Render"]),

        // What the Notes app draws: the list of the notes and the editor.
        // The app around it, which reads and writes ~/Notes, is
        // ui/Sources/NotesApp.
        .target(name: "Notes", dependencies: ["Toolkit", "Render"]),

        // What the Power app draws, and what it makes of the files of
        // /sys/class/power_supply. The app around it, which reads them, is
        // ui/Sources/PowerApp.
        .target(name: "Power", dependencies: ["Toolkit", "Render"]),

        // How long a frame takes: swift run -c release toolkit-bench
        .executableTarget(name: "toolkit-bench", dependencies: ["Shell", "Toolkit", "Render"]),

        .testTarget(name: "RenderTests", dependencies: ["Render"]),
        .testTarget(name: "ToolkitTests", dependencies: ["Toolkit", "Render"]),
        .testTarget(name: "ShellTests", dependencies: ["Shell", "Toolkit", "Render"]),
        .testTarget(name: "TerminalTests", dependencies: ["Terminal", "Toolkit", "Render"]),
        .testTarget(name: "SettingsTests", dependencies: ["Settings", "Toolkit", "Render"]),
        .testTarget(name: "FilesTests", dependencies: ["Files", "Toolkit", "Render"]),
        .testTarget(name: "NotesTests", dependencies: ["Notes", "Toolkit", "Render"]),
        .testTarget(name: "PowerTests", dependencies: ["Power", "Toolkit", "Render"]),
    ]
)
