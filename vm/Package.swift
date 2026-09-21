// swift-tools-version: 6.4
//
// mydistro-vm: the host side of testing. It boots the mydistro images in a
// virtual machine on the Mac with Apple's Virtualization framework.
//
// This package builds for macOS only, with the Swift toolchain of Xcode
// (`xcrun swift build`), not the swift.org toolchain in build/cache that
// compiles ui/. Virtualization and AppKit are Apple frameworks, so the
// toolchain of the platform is the one that has them.
//
// The program needs the com.apple.security.virtualization entitlement.
// `make vm` signs it; see Makefile.

import PackageDescription

let package = Package(
    name: "mydistro-vm",
    platforms: [.macOS(.v14)],
    targets: [
        // virglrenderer. The Makefile passes the include directory and the
        // library, and defines VIRGL, when build/cache holds a build of it.
        .systemLibrary(name: "CVirgl", path: "Sources/CVirgl"),
        .executableTarget(name: "mydistro-vm", dependencies: ["CVirgl"],
                          path: "Sources/mydistro-vm"),
    ]
)
