// swift-tools-version: 6.0
//
// wayland-swift-scanner: makes Swift code from Wayland protocol XML files,
// for the server side. It runs on the Mac (`make protocols`); the output is
// committed in ui/Sources/Wayland/Protocols/.

import PackageDescription

let package = Package(
    name: "WaylandScanner",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "wayland-swift-scanner"),
    ]
)
