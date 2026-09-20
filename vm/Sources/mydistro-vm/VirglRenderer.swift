#if VIRGL
import CVirgl
import Foundation

/// virglrenderer: the renderer on this side of the GPU.
///
/// The guest's Mesa speaks Venus, which is Vulkan calls in a stream.
/// virglrenderer reads that stream and makes the same calls to Vulkan here,
/// where MoltenVK turns them into Metal. See docs/gpu.md.
///
/// build/make-virglrenderer.sh builds the library. Without it the Makefile
/// leaves VIRGL undefined and this file is not in the program at all.
final class VirglRenderer {
    /// The capset numbers of the Virtio GPU specification. A capset says
    /// which kind of context a guest can ask for.
    enum Capset: UInt32 {
        case virgl = 1
        case virgl2 = 2
        case gfxstream = 3
        case venus = 4
        case crossDomain = 5
        case drm = 6
    }

    struct CapsetInfo {
        let version: UInt32
        let size: UInt32
    }

    /// virglrenderer keeps one renderer for the process.
    nonisolated(unsafe) private static var started = false

    /// Starts the renderer for Venus, with no OpenGL renderer under it.
    /// macOS has no EGL, and the OpenGL half of virglrenderer is not built.
    static func start() throws(GPUFailure) {
        guard !started else { return }

        var callbacks = virgl_renderer_callbacks()
        // Version 3 is the first with per-context fences, which Venus uses.
        // The OpenGL callbacks stay nil: nothing here makes a GL context.
        callbacks.version = 3

        let flags = Int32(VIRGL_RENDERER_VENUS | VIRGL_RENDERER_NO_VIRGL
            | VIRGL_RENDERER_THREAD_SYNC | VIRGL_RENDERER_USE_EXTERNAL_BLOB)
        let result = virgl_renderer_init(nil, flags, &callbacks)
        guard result == 0 else {
            throw .renderer("virgl_renderer_init failed (\(result)); "
                + "is MoltenVK installed? brew install molten-vk")
        }
        started = true
    }

    /// What the renderer says about a capset.
    ///
    /// Venus always answers with a version of 0: the version is in the
    /// capset itself. The size is what says whether the renderer has it.
    static func capset(_ capset: Capset) -> CapsetInfo {
        var version: UInt32 = 0
        var size: UInt32 = 0
        virgl_renderer_get_cap_set(capset.rawValue, &version, &size)
        return CapsetInfo(version: version, size: size)
    }

    /// The bytes of a capset, which the guest reads with GET_CAPSET.
    static func capsetData(_ capset: Capset, version: UInt32, size: UInt32) -> Data {
        var bytes = [UInt8](repeating: 0, count: Int(size))
        bytes.withUnsafeMutableBytes { raw in
            virgl_renderer_fill_caps(capset.rawValue, version, raw.baseAddress)
        }
        return Data(bytes)
    }
}

enum GPUFailure: Error, CustomStringConvertible {
    case renderer(String)

    var description: String {
        switch self { case .renderer(let message): message }
    }
}
#endif
