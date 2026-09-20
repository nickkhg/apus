import CDRM
import CEGL
import CGBM
import CGLES
import DRMKit
import Glibc
import Render

/// Draws with the GPU and shows the result on the display.
///
/// The chain is the usual one for a Wayland compositor with no window
/// system under it:
///
/// 1. GBM makes buffers from the same DRM device that the display uses.
/// 2. EGL draws into those buffers, with the GBM platform.
/// 3. GLES draws the display list (see GLRenderer).
/// 4. eglSwapBuffers finishes a buffer; the buffer becomes a KMS
///    framebuffer, and a page flip puts it on the display.
///
/// In a VM there is no GPU, so Mesa renders with the CPU (llvmpipe). The
/// code path is the same, which is why the tests can run it.
final class GPUScreen: Screen, PageFlipHandler {
    let usesGPU = true
    let device: DRMDevice
    private(set) var output: Output
    var width: Int { output.mode.width }
    var height: Int { output.mode.height }
    var widthInMillimetres: Int? {
        output.widthInMillimetres > 0 ? output.widthInMillimetres : nil
    }

    var displayList: () -> DisplayList = { [] }
    var frameShown: () -> Void = {}
    var sizeChanged: () -> Void = {}

    /// XRGB8888: the display shows these, and they have no alpha to blend
    /// with anything behind, because nothing is behind the screen. GBM and
    /// DRM use the same numbers for formats.
    private static let format = CDRM_FORMAT_XRGB8888

    private let gbm: OpaquePointer            // struct gbm_device *
    private var surface: OpaquePointer?       // struct gbm_surface *
    private let display: EGLDisplay
    private let config: EGLConfig
    private let context: EGLContext
    private var eglSurface: EGLSurface?
    private let renderer: GLRenderer

    /// The buffer that the display shows, and the one before it. GBM lends
    /// a buffer until the display stops using it.
    private var shown: (bo: OpaquePointer, framebuffer: ImportedFramebuffer)?
    private var pendingRelease: OpaquePointer?

    private var restore: ScreenRestore?
    private var flipPending = false
    private var needsFrame = false
    private var canPageFlip = true
    /// True while a frame is being drawn.
    private var isDrawing = false
    private var displayMayHaveChanged = false

    init(device: DRMDevice) throws {
        guard let output = try device.connectedOutputs().first else { throw DRMError.noDevice }
        self.device = device
        self.output = output

        guard let gbm = gbm_create_device(device.fd) else {
            throw GLFailure.display("gbm_create_device failed on \(device.path)")
        }
        self.gbm = gbm

        (display, config, context) = try GPUScreen.startEGL(gbm: gbm)
        // The surface comes before the renderer: compiling a shader needs a
        // current context, and a context becomes current on a surface.
        (surface, eglSurface) = try GPUScreen.createSurface(
            gbm: gbm, display: display, config: config, context: context,
            width: output.mode.width, height: output.mode.height)
        renderer = try GLRenderer()

        // The first frame must exist before the display can show it.
        let first = try drawIntoBuffer()
        restore = try device.show(first.framebuffer, on: output)
        shown = first
        log("GPU-RENDERER \(GPUScreen.describe())")
    }

    deinit {
        releaseBuffers()
        eglMakeCurrent(display, nil, nil, nil)
        if let eglSurface { eglDestroySurface(display, eglSurface) }
        eglDestroyContext(display, context)
        eglTerminate(display)
        if let surface { gbm_surface_destroy(surface) }
        gbm_device_destroy(gbm)
    }

    // MARK: - Setting up

    private static func startEGL(
        gbm: OpaquePointer
    ) throws -> (EGLDisplay, EGLConfig, EGLContext) {
        // eglGetPlatformDisplay is EGL 1.5; the EXT function works with the
        // older libraries too, and Mesa has it.
        guard let getPlatformDisplay = unsafeBitCast(
            eglGetProcAddress("eglGetPlatformDisplayEXT"),
            to: (@convention(c) (EGLenum, UnsafeMutableRawPointer?,
                                 UnsafePointer<EGLint>?) -> EGLDisplay?)?.self)
        else {
            throw GLFailure.display("EGL has no eglGetPlatformDisplayEXT")
        }
        guard let display = getPlatformDisplay(
            EGLenum(EGL_PLATFORM_GBM_KHR), UnsafeMutableRawPointer(gbm), nil)
        else {
            throw GLFailure.display("no EGL display for the GBM device")
        }

        var major: EGLint = 0, minor: EGLint = 0
        guard eglInitialize(display, &major, &minor) == EGL_TRUE else {
            throw GLFailure.display("eglInitialize failed (0x\(String(eglGetError(), radix: 16)))")
        }
        guard eglBindAPI(EGLenum(EGL_OPENGL_ES_API)) == EGL_TRUE else {
            throw GLFailure.display("no OpenGL ES in this EGL")
        }

        let wanted: [EGLint] = [
            EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
            EGL_ALPHA_SIZE, 0,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
            EGL_NONE,
        ]
        var count: EGLint = 0
        guard eglChooseConfig(display, wanted, nil, 0, &count) == EGL_TRUE, count > 0 else {
            throw GLFailure.display("no EGL config for 8-bit colour")
        }
        var configs = [EGLConfig?](repeating: nil, count: Int(count))
        eglChooseConfig(display, wanted, &configs, count, &count)

        // The config must make buffers in the format that the display
        // scans out, or the page flip is refused.
        var chosen: EGLConfig?
        for candidate in configs.prefix(Int(count)) {
            var visual: EGLint = 0
            guard eglGetConfigAttrib(display, candidate, EGL_NATIVE_VISUAL_ID, &visual) == EGL_TRUE
            else { continue }
            if UInt32(bitPattern: visual) == format { chosen = candidate; break }
        }
        guard let config = chosen else {
            throw GLFailure.display("no EGL config gives XRGB8888 buffers")
        }

        let attributes: [EGLint] = [EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE]
        guard let context = eglCreateContext(display, config, nil, attributes) else {
            throw GLFailure.display("eglCreateContext failed")
        }
        return (display, config, context)
    }

    /// Makes the GBM surface and the EGL surface for a size, and makes the
    /// context current on it. Nothing of `self` is read, so the caller can
    /// use this before every property is set.
    private static func createSurface(
        gbm: OpaquePointer, display: EGLDisplay, config: EGLConfig, context: EGLContext,
        width: Int, height: Int
    ) throws -> (OpaquePointer, EGLSurface) {
        guard let surface = gbm_surface_create(
            gbm, UInt32(width), UInt32(height), GPUScreen.format,
            UInt32(GBM_BO_USE_SCANOUT.rawValue | GBM_BO_USE_RENDERING.rawValue))
        else {
            throw GLFailure.display("gbm_surface_create failed for \(width)x\(height)")
        }

        guard let createWindowSurface = unsafeBitCast(
            eglGetProcAddress("eglCreatePlatformWindowSurfaceEXT"),
            to: (@convention(c) (EGLDisplay?, EGLConfig?, UnsafeMutableRawPointer?,
                                 UnsafePointer<EGLint>?) -> EGLSurface?)?.self)
        else {
            throw GLFailure.display("EGL has no eglCreatePlatformWindowSurfaceEXT")
        }
        guard let eglSurface = createWindowSurface(
            display, config, UnsafeMutableRawPointer(surface), nil)
        else {
            gbm_surface_destroy(surface)
            throw GLFailure.display("no EGL surface for the GBM surface")
        }
        guard eglMakeCurrent(display, eglSurface, eglSurface, context) == EGL_TRUE else {
            throw GLFailure.display("eglMakeCurrent failed")
        }
        // The display sets the pace with its page flips, not EGL.
        eglSwapInterval(display, 0)
        return (surface, eglSurface)
    }

    /// Puts a surface of a new size in place of the one there now.
    private func replaceSurface(width: Int, height: Int) throws {
        if let eglSurface {
            eglMakeCurrent(display, nil, nil, nil)
            eglDestroySurface(display, eglSurface)
            self.eglSurface = nil
        }
        if let surface { gbm_surface_destroy(surface); self.surface = nil }
        (surface, eglSurface) = try GPUScreen.createSurface(
            gbm: gbm, display: display, config: config, context: context,
            width: width, height: height)
    }

    private static func describe() -> String {
        func text(_ name: GLenum) -> String {
            glGetString(name).map { String(cString: $0) } ?? "?"
        }
        return "\(text(GLenum(GL_RENDERER))) \(text(GLenum(GL_VERSION)))"
    }

    // MARK: - Frames

    func setNeedsFrame() {
        needsFrame = true
        // A frame that is being drawn must not start another one. Something
        // that moves asks for the next frame while this one is drawn, and
        // the flip that follows picks it up.
        if !flipPending, !isDrawing { drawFrame() }
    }

    /// Draws the list and takes the finished buffer from GBM.
    private func drawIntoBuffer() throws -> (bo: OpaquePointer, framebuffer: ImportedFramebuffer) {
        renderer.render(displayList(), width: width, height: height)
        guard eglSwapBuffers(display, eglSurface) == EGL_TRUE else {
            throw GLFailure.display("eglSwapBuffers failed")
        }
        guard let surface, let bo = gbm_surface_lock_front_buffer(surface) else {
            throw GLFailure.display("no finished buffer from GBM")
        }
        let framebuffer = try ImportedFramebuffer(
            device: device, width: width, height: height, format: GPUScreen.format,
            handle: gbm_bo_get_handle(bo).u32, pitch: gbm_bo_get_stride(bo))
        return (bo, framebuffer)
    }

    private func drawFrame() {
        isDrawing = true
        defer { isDrawing = false }
        needsFrame = false
        guard let surface else { return }
        let next: (bo: OpaquePointer, framebuffer: ImportedFramebuffer)
        do {
            next = try drawIntoBuffer()
        } catch {
            log("screen: \(error)")
            return
        }

        if canPageFlip {
            do {
                try device.schedulePageFlip(next.framebuffer, on: output, handler: self)
                flipPending = true
                // GBM keeps the old buffer until the display stops reading
                // it, which is when the flip finishes.
                pendingRelease = shown?.bo
                shown = next
                return
            } catch {
                log("screen: page flip not available (\(error)); using mode sets")
                canPageFlip = false
            }
        }
        try? device.setFramebuffer(next.framebuffer, on: output)
        if let old = shown?.bo { gbm_surface_release_buffer(surface, old) }
        shown = next
        pageFlipCompleted()
    }

    func pageFlipCompleted() {
        flipPending = false
        if let surface, let old = pendingRelease {
            gbm_surface_release_buffer(surface, old)
            pendingRelease = nil
        }
        frameShown()
        if displayMayHaveChanged { takeNewMode() }
        if needsFrame { drawFrame() }
    }

    // MARK: - Size

    func displayChanged() {
        displayMayHaveChanged = true
        if !flipPending { takeNewMode() }
    }

    private func takeNewMode() {
        displayMayHaveChanged = false
        guard let outputs = try? device.connectedOutputs() else { return }
        guard let latest = outputs.first(where: { $0.connectorID == output.connectorID })
                ?? outputs.first else { return }
        guard latest.mode.width != width || latest.mode.height != height else { return }

        let previous = output
        output = latest
        do {
            // The buffers of the old size go away with their surface, so
            // nothing of the old size is left for the display to read.
            releaseBuffers()
            try replaceSurface(width: latest.mode.width, height: latest.mode.height)
            let first = try drawIntoBuffer()
            try device.setFramebuffer(first.framebuffer, on: output)
            shown = first
        } catch {
            log("screen: cannot take \(latest.mode): \(error)")
            output = previous
            return
        }
        log("SCREEN-MODE \(latest.mode)")
        sizeChanged()
        setNeedsFrame()
    }

    // MARK: - Pictures

    /// Draws the list again into a framebuffer of its own and reads the
    /// pixels back. Reading the buffer that the display shows is not
    /// possible: GBM lent it to the display, and it is not mapped.
    ///
    /// Drawing is the same each time for the same list, so these pixels are
    /// the pixels on the screen.
    func writePicture(to path: String) throws {
        var texture: GLuint = 0
        var framebuffer: GLuint = 0
        glGenTextures(1, &texture)
        glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA, GLsizei(width), GLsizei(height), 0,
                     GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_NEAREST)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_NEAREST)
        glGenFramebuffers(1, &framebuffer)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                               GLenum(GL_TEXTURE_2D), texture, 0)
        defer {
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
            glDeleteFramebuffers(1, &framebuffer)
            glDeleteTextures(1, &texture)
        }
        guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
                == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            throw GLFailure.display("cannot make a framebuffer to read back")
        }

        renderer.render(displayList(), width: width, height: height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            glReadPixels(0, 0, GLsizei(width), GLsizei(height),
                         GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), bytes.baseAddress)
        }
        // glReadPixels counts rows from the bottom; a PPM counts from the top.
        try PPM.write(width: width, height: height, to: path) { x, y in
            let index = ((height - 1 - y) * width + x) * 4
            return (UInt32(pixels[index]) << 16)
                | (UInt32(pixels[index + 1]) << 8)
                | UInt32(pixels[index + 2])
        }
    }

    func release() {
        restore?.restore()
        restore = nil
        releaseBuffers()
    }

    /// Gives every locked buffer back to GBM. gbm_surface_destroy waits for
    /// its buffers, so a surface with a locked buffer never goes away and
    /// the compositor does not stop.
    private func releaseBuffers() {
        guard let surface else { return }
        if let bo = pendingRelease { gbm_surface_release_buffer(surface, bo) }
        pendingRelease = nil
        if let bo = shown?.bo { gbm_surface_release_buffer(surface, bo) }
        shown = nil
    }
}
