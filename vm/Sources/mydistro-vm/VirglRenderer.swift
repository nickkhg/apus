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

        // RENDER_SERVER is what turns Venus on. Without it virglrenderer
        // answers every capset request with zeros, and the guest's Mesa
        // reads a wire format version of 0 and takes no device. The build
        // puts the render server in this process, as a thread, so the flag
        // starts a thread and not a second program.
        //
        // ASYNC_FENCE_CB goes with THREAD_SYNC: the Venus renderer refuses
        // to start without both.
        let flags = Int32(VIRGL_RENDERER_VENUS | VIRGL_RENDERER_NO_VIRGL
            | VIRGL_RENDERER_THREAD_SYNC | VIRGL_RENDERER_ASYNC_FENCE_CB
            | VIRGL_RENDERER_RENDER_SERVER | VIRGL_RENDERER_USE_EXTERNAL_BLOB)
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

#if VIRGL
extension VirglRenderer {
    /// Makes a context for a capset. Venus asks for one before it does
    /// anything else, and every stream of commands goes to a context.
    static func createContext(id: UInt32, capset: UInt32, name: String) -> Int32 {
        var result: Int32 = -1
        name.withCString { text in
            result = virgl_renderer_context_create_with_flags(
                id, capset, UInt32(strlen(text)), text)
        }
        return result
    }

    static func destroyContext(id: UInt32) {
        virgl_renderer_context_destroy(id)
    }

    /// Gives a stream of commands to a context. For Venus the stream is
    /// Vulkan calls, and virglrenderer makes the same calls here.
    static func submit(_ commands: inout [UInt8], context: UInt32) -> Int32 {
        commands.withUnsafeMutableBytes { raw in
            // The count is in 32-bit words, as the specification says.
            virgl_renderer_submit_cmd(raw.baseAddress, Int32(context),
                                      Int32(raw.count / 4))
        }
    }

    /// A resource that is memory rather than a picture.
    static func createBlob(resource: UInt32, context: UInt32, memory: UInt32,
                           flags: UInt32, blobID: UInt64, size: UInt64) -> Int32 {
        var args = virgl_renderer_resource_create_blob_args()
        args.res_handle = resource
        args.ctx_id = context
        args.blob_mem = memory
        args.blob_flags = flags
        args.blob_id = blobID
        args.size = size
        args.iovecs = nil
        args.num_iovs = 0
        return virgl_renderer_resource_create_blob(&args)
    }

    /// Where a blob is in this process, and how large it is. The guest
    /// cannot read that memory until it is put in the shared region.
    static func map(resource: UInt32) -> (address: UnsafeMutableRawPointer, size: UInt64)? {
        var address: UnsafeMutableRawPointer?
        var size: UInt64 = 0
        guard virgl_renderer_resource_map(resource, &address, &size) == 0,
              let address else { return nil }
        return (address, size)
    }

    static func unmap(resource: UInt32) {
        _ = virgl_renderer_resource_unmap(resource)
    }

    /// How the guest may cache a blob: none, cached, uncached or
    /// write-combining. The guest needs it in the answer to a map.
    static func mapInfo(resource: UInt32) -> UInt32 {
        var info: UInt32 = 0
        guard virgl_renderer_resource_get_map_info(resource, &info) == 0 else {
            return UInt32(VIRGL_RENDERER_MAP_CACHE_CACHED)
        }
        return info
    }

    static func attach(resource: UInt32, toContext context: UInt32) {
        virgl_renderer_ctx_attach_resource(Int32(context), Int32(resource))
    }

    static func detach(resource: UInt32, fromContext context: UInt32) {
        virgl_renderer_ctx_detach_resource(Int32(context), Int32(resource))
    }

    static func unref(resource: UInt32) {
        virgl_renderer_resource_unref(resource)
    }

    /// Lets the renderer finish what it can. The device calls this after a
    /// stream, so that a guest that waits for a fence is not left waiting.
    static func poll() {
        virgl_renderer_poll()
    }
}
#endif
