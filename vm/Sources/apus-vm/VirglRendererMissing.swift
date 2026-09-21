#if !VIRGL
import Foundation

/// The renderer, for a build that has none.
///
/// `make vm` builds virglrenderer first (build/make-virglrenderer.sh), so a
/// normal build defines VIRGL and uses the real one in VirglRenderer.swift.
/// A Mac with no Homebrew cannot build the renderer. The build says so and
/// goes on, and this file is what `VirtioGPUDevice` then calls.
///
/// `VirtioGPUDevice.renderer(_:)` runs no work when VIRGL is undefined, so
/// nothing here is ever called. It exists because the compiler reads the
/// body of every closure, and a closure that names a type which is not
/// there does not compile. Without this file the whole program fails to
/// build on such a Mac, which is the fault that a clone on a second machine
/// found.
///
/// The answers say "no renderer": 0 means success to this device, so each
/// number here is one that it reads as a failure.
enum VirglRenderer {
    static func onFence(_ handler: @escaping (UInt32, UInt32, UInt64) -> Void) {}

    static func createContext(id: UInt32, capset: UInt32, name: String) -> Int32 { -1 }
    static func destroyContext(id: UInt32) {}

    static func submit(_ commands: inout [UInt8], context: UInt32) -> Int32 { -1 }

    static func createBlob(resource: UInt32, context: UInt32, memory: UInt32,
                           flags: UInt32, blobID: UInt64, size: UInt64) -> Int32 { -1 }

    static func map(resource: UInt32) -> (address: UnsafeMutableRawPointer, size: UInt64)? { nil }
    static func unmap(resource: UInt32) {}
    static func mapInfo(resource: UInt32) -> UInt32 { 0 }

    static func attach(resource: UInt32, toContext context: UInt32) {}
    static func detach(resource: UInt32, fromContext context: UInt32) {}
    static func unref(resource: UInt32) {}

    static func createFence(context: UInt32, ringIndex: UInt32, fenceID: UInt64) -> Int32 { -1 }
    static func poll(context: UInt32) {}
}
#endif
