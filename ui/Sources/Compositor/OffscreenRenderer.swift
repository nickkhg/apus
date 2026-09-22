import CEGL
import CGLES
import Glibc
import Render

/// Draws with the GPU into memory, and gives the pixels back.
///
/// GPUScreen draws through GBM, which is how a compositor normally reaches
/// the display: the buffer it draws into is the buffer the display reads.
/// That needs a Vulkan or GL driver that can export a dma-buf, and in a
/// virtual machine on a Mac there is none. Venus offers no dma-buf, because
/// Metal has nothing to export. `gbm_create_device` fails and the GPU stays
/// out of reach. See docs/gpu.md.
///
/// This draws with no window system at all. EGL takes the surfaceless
/// platform, GLES draws into a texture, and the frame is read back into the
/// buffer the display reads. The read costs one copy of the screen for each
/// frame, and everything above it is the same GLRenderer that GPUScreen
/// uses, so the two draw the same pictures.
final class OffscreenRasterizer: FrameRasterizer {
    let usesGPU = true
    let name = "gpu"

    private let display: EGLDisplay
    private let context: EGLContext
    private let renderer: GLRenderer

    /// Two framebuffers and two textures.
    ///
    /// A frame drawn into the same texture that the read of the frame before
    /// it has not finished with makes the GPU wait, and the drawing then
    /// costs what the waiting used to. With one of each per frame nothing
    /// meets anything.
    private var framebuffers: [GLuint] = [0, 0]
    private var textures: [GLuint] = [0, 0]
    private var width = 0
    private var height = 0
    /// What glReadPixels gives. With GL_BGRA_EXT the bytes arrive in the
    /// order the display wants, and the rows only change place. With
    /// GL_RGBA red and blue change place as well.
    private var readFormat = GLenum(GL_RGBA)
    /// Where a frame lands before it goes into the buffer of the display.
    /// GL counts rows from the bottom and the display counts them from the
    /// top, so no frame goes straight across.
    private var staging: UnsafeMutableRawPointer?
    private var stagingBytes = 0
    /// The two buffers that a frame is read into.
    ///
    /// A read straight into memory stops until the GPU has finished the
    /// frame, and on this machine that wait is the whole cost of a frame:
    /// the GPU draws for microseconds and the answer takes milliseconds to
    /// come back. A read into one of these asks for the pixels and returns,
    /// and the frame after it takes the pixels of the frame before. The
    /// screen is then one frame behind, and nothing waits.
    private var packBuffers: [GLuint] = [0, 0]
    private var packBytes = 0
    /// Which buffer the next frame is read into, and whether the other one
    /// holds a frame yet.
    private var packIndex = 0
    private var packHasFrame = false
    /// GL_EXT_map_buffer_range and GL_OES_mapbuffer, which read one of those
    /// buffers. Without them the read back goes straight into memory and
    /// waits, as it did before.
    private let mapBufferRange: MapBufferRange?
    private let unmapBuffer: UnmapBuffer?

    private typealias MapBufferRange = @convention(c)
        (GLenum, GLintptr, GLsizeiptr, GLbitfield) -> UnsafeMutableRawPointer?
    private typealias UnmapBuffer = @convention(c) (GLenum) -> GLboolean

    init() throws(GLFailure) {
        (display, context) = try OffscreenRasterizer.startEGL()
        mapBufferRange = unsafeBitCast(
            eglGetProcAddress("glMapBufferRangeEXT"), to: MapBufferRange?.self)
        unmapBuffer = unsafeBitCast(
            eglGetProcAddress("glUnmapBufferOES"), to: UnmapBuffer?.self)
        // The context is current, so a shader can compile.
        renderer = try GLRenderer()
        log("GPU-RENDERER \(OffscreenRasterizer.describe()) (offscreen)")
        log("screen: a frame comes back "
            + (mapBufferRange != nil && unmapBuffer != nil
               ? "without waiting, one frame behind" : "and the GPU is waited for"))
    }

    deinit {
        if framebuffers[0] != 0 { glDeleteFramebuffers(2, &framebuffers) }
        if textures[0] != 0 { glDeleteTextures(2, &textures) }
        if packBuffers[0] != 0 { glDeleteBuffers(2, &packBuffers) }
        staging?.deallocate()
        eglMakeCurrent(display, nil, nil, nil)
        eglDestroyContext(display, context)
        eglTerminate(display)
    }

    // MARK: - Setting up

    private typealias GetPlatformDisplay =
        @convention(c) (EGLenum, UnsafeMutableRawPointer?,
                        UnsafePointer<EGLint>?) -> EGLDisplay?
    private typealias QueryDevices =
        @convention(c) (EGLint, UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
                        UnsafeMutablePointer<EGLint>?) -> EGLBoolean
    private typealias QueryDeviceString =
        @convention(c) (UnsafeMutableRawPointer?, EGLint) -> UnsafePointer<CChar>?

    /// An EGL display and context with nothing under them.
    ///
    /// A context with no surface is EGL_KHR_surfaceless_context: it gives
    /// something to draw with, and the caller says where the pixels go.
    ///
    /// Which device draws is the question this has to answer. A machine can
    /// hold more than one, and only one of them may have a GPU behind it: a
    /// virtual machine on a Mac has the plain device of the framework beside
    /// the one that carries Venus. The surfaceless platform takes the first
    /// device it finds, and Zink then looks for a Vulkan device with the
    /// same DRM number and finds none, so EGL gives up with no driver at
    /// all. The device platform names the device instead.
    ///
    /// So this asks EGL for its devices and takes the first one that draws
    /// with a GPU. With none, it takes the first that works at all, which is
    /// the software renderer, and the picture is the same either way.
    /// APUS_RENDER_NODE names one device and stops the search.
    private static func startEGL() throws(GLFailure) -> (EGLDisplay, EGLContext) {
        guard let getPlatformDisplay = unsafeBitCast(
            eglGetProcAddress("eglGetPlatformDisplayEXT"), to: GetPlatformDisplay?.self)
        else {
            throw .display("EGL has no eglGetPlatformDisplayEXT")
        }
        let wanted = getenv("APUS_RENDER_NODE").map { String(cString: $0) }

        var software: (EGLDisplay, EGLContext)?
        for device in devices() {
            let node = deviceNode(device)
            if let wanted, node != wanted { continue }
            guard let display = getPlatformDisplay(
                EGLenum(EGL_PLATFORM_DEVICE_EXT), device, nil),
                let opened = open(display) else { continue }

            if describe().contains("llvmpipe") || describe().contains("softpipe") {
                if software == nil {
                    software = opened
                } else {
                    close(opened)
                }
                continue
            }
            log("screen: the GPU of \(node ?? "an unnamed device") draws the frames")
            if let software { close(software) }
            return opened
        }
        if let software { return software }

        // No device platform, or nothing on it. The surfaceless platform
        // takes whatever it finds, which is what every other Linux machine
        // with one GPU gives.
        guard wanted == nil, let display = getPlatformDisplay(
            EGLenum(EGL_PLATFORM_SURFACELESS_MESA), nil, nil), let opened = open(display)
        else {
            throw .display("no EGL device draws"
                + (wanted.map { " for APUS_RENDER_NODE=\($0)" } ?? ""))
        }
        return opened
    }

    /// The devices EGL knows about. An EGL without the extension gives none,
    /// and the caller then takes the surfaceless platform.
    private static func devices() -> [UnsafeMutableRawPointer?] {
        guard let queryDevices = unsafeBitCast(
            eglGetProcAddress("eglQueryDevicesEXT"), to: QueryDevices?.self) else { return [] }
        var count: EGLint = 0
        guard queryDevices(0, nil, &count) == EGL_TRUE, count > 0 else { return [] }
        var found = [UnsafeMutableRawPointer?](repeating: nil, count: Int(count))
        guard queryDevices(count, &found, &count) == EGL_TRUE else { return [] }
        return Array(found.prefix(Int(count)))
    }

    /// The render node of a device, for the log and for APUS_RENDER_NODE.
    private static func deviceNode(_ device: UnsafeMutableRawPointer?) -> String? {
        guard let queryString = unsafeBitCast(
            eglGetProcAddress("eglQueryDeviceStringEXT"), to: QueryDeviceString?.self)
        else { return nil }
        // EGL_DRM_RENDER_NODE_FILE_EXT, from EGL_EXT_device_drm_render_node.
        return queryString(device, 0x3377).map { String(cString: $0) }
    }

    /// Starts a display and makes a context current on it. Gives back
    /// nothing when this display has no driver behind it.
    private static func open(_ display: EGLDisplay) -> (EGLDisplay, EGLContext)? {
        var major: EGLint = 0, minor: EGLint = 0
        guard eglInitialize(display, &major, &minor) == EGL_TRUE else { return nil }
        guard eglBindAPI(EGLenum(EGL_OPENGL_ES_API)) == EGL_TRUE else {
            eglTerminate(display)
            return nil
        }
        let wanted: [EGLint] = [
            EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
            EGL_ALPHA_SIZE, 8,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
            EGL_NONE,
        ]
        var config: EGLConfig?
        var count: EGLint = 0
        guard eglChooseConfig(display, wanted, &config, 1, &count) == EGL_TRUE, count > 0 else {
            eglTerminate(display)
            return nil
        }
        let attributes: [EGLint] = [EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE]
        guard let context = eglCreateContext(display, config, nil, attributes) else {
            eglTerminate(display)
            return nil
        }
        guard eglMakeCurrent(display, nil, nil, context) == EGL_TRUE else {
            eglDestroyContext(display, context)
            eglTerminate(display)
            return nil
        }
        return (display, context)
    }

    private static func close(_ opened: (EGLDisplay, EGLContext)) {
        eglMakeCurrent(opened.0, nil, nil, nil)
        eglDestroyContext(opened.0, opened.1)
        eglTerminate(opened.0)
    }

    /// The first GL error since the last time this was asked, as a name.
    /// Reported once for each kind, so a fault in every frame says it one
    /// time.
    private var reported: Set<GLenum> = []
    private func firstError() -> String? {
        let code = glGetError()
        while glGetError() != GLenum(GL_NO_ERROR) {}
        guard code != GLenum(GL_NO_ERROR), reported.insert(code).inserted else { return nil }
        switch Int32(code) {
        case GL_INVALID_ENUM: return "an invalid enum"
        case GL_INVALID_VALUE: return "an invalid value"
        case GL_INVALID_OPERATION: return "an invalid operation"
        case GL_OUT_OF_MEMORY: return "no memory"
        case GL_INVALID_FRAMEBUFFER_OPERATION: return "an unusable framebuffer"
        default: return "error 0x\(String(code, radix: 16))"
        }
    }

    private static func describe() -> String {
        func text(_ name: GLenum) -> String {
            glGetString(name).map { String(cString: $0) } ?? "?"
        }
        return "\(text(GLenum(GL_RENDERER))) \(text(GLenum(GL_VERSION)))"
    }

    /// Makes the texture that a frame is drawn into, at this size.
    ///
    /// BGRA comes first, because the display wants those bytes in that
    /// order and a frame in that order needs no work for each pixel. A
    /// driver that cannot draw into BGRA gets RGBA, and then red and blue
    /// change place on the way out.
    private func prepare(width: Int, height: Int) -> Bool {
        if width == self.width, height == self.height, framebuffers[0] != 0 { return true }
        if framebuffers[0] == 0 { glGenFramebuffers(2, &framebuffers) }
        if textures[0] == 0 { glGenTextures(2, &textures) }

        for format in [GLenum(GL_BGRA_EXT), GLenum(GL_RGBA)] {
            for which in 0..<2 {
                glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffers[which])
                glBindTexture(GLenum(GL_TEXTURE_2D), textures[which])
                glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_NEAREST)
                glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_NEAREST)
                glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
                glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
                glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GLint(format),
                             GLsizei(width), GLsizei(height), 0,
                             format, GLenum(GL_UNSIGNED_BYTE), nil)
                glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                                       GLenum(GL_TEXTURE_2D), textures[which], 0)
            }
            guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
                == GLenum(GL_FRAMEBUFFER_COMPLETE) else { continue }

            // What the driver would rather give back. It answers with the
            // format of the texture when it can.
            var reported: GLint = 0
            glGetIntegerv(GLenum(GL_IMPLEMENTATION_COLOR_READ_FORMAT), &reported)
            readFormat = GLenum(reported) == GLenum(GL_BGRA_EXT)
                ? GLenum(GL_BGRA_EXT) : GLenum(GL_RGBA)

            self.width = width
            self.height = height
            log("screen: the GPU draws into "
                + (format == GLenum(GL_BGRA_EXT) ? "BGRA" : "RGBA")
                + " and reads back "
                + (readFormat == GLenum(GL_BGRA_EXT) ? "BGRA" : "RGBA"))
            let bytes = width * height * 4
            if bytes > stagingBytes {
                staging?.deallocate()
                staging = .allocate(byteCount: bytes, alignment: 16)
                stagingBytes = bytes
            }
            if packBuffers[0] == 0 { glGenBuffers(2, &packBuffers) }
            if bytes != packBytes {
                for buffer in packBuffers {
                    glBindBuffer(CGLES_PIXEL_PACK_BUFFER, buffer)
                    glBufferData(CGLES_PIXEL_PACK_BUFFER, bytes, nil, CGLES_STREAM_READ)
                }
                glBindBuffer(CGLES_PIXEL_PACK_BUFFER, 0)
                packBytes = bytes
                packHasFrame = false
                packIndex = 0
            }
            return true
        }
        log("screen: the GPU draws into neither BGRA nor RGBA at \(width)x\(height)")
        self.width = 0
        self.height = 0
        return false
    }

    /// Times the parts of a frame, to say what the read back really costs.
/// APUS_SPLIT_LOG=N writes a line for each N frames.
enum Split {
    nonisolated(unsafe) static var submit = 0.0
    nonisolated(unsafe) static var flush = 0.0
    nonisolated(unsafe) static var draw = 0.0
    nonisolated(unsafe) static var read = 0.0
    nonisolated(unsafe) static var copy = 0.0
    nonisolated(unsafe) static var frames = 0
    static let every: Int = {
        guard let text = getenv("APUS_SPLIT_LOG").map({ String(cString: $0) }),
              let count = Int(text), count > 0 else { return 0 }
        return count
    }()

    static func now() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    static func add(submit s: Double, flush f: Double, draw d: Double,
                    read r: Double, copy c: Double, width: Int, height: Int) {
        guard every > 0 else { return }
        submit += s; flush += f; draw += d; read += r; copy += c
        frames += 1
        guard frames >= every else { return }
        func ms(_ v: Double) -> Double { (v / Double(frames) * 10_000).rounded() / 10 }
        let total = submit + flush + draw + read + copy
        log("SPLIT \(width)x\(height) record \(ms(submit))ms flush \(ms(flush))ms"
            + " wait \(ms(draw))ms read \(ms(read))ms copy \(ms(copy))ms"
            + " (total \(ms(total))ms)")
        submit = 0; flush = 0; draw = 0; read = 0; copy = 0; frames = 0
    }
}

// MARK: - Frames

    func render(_ list: DisplayList, into pixels: UnsafeMutablePointer<UInt32>,
                width: Int, height: Int, stride: Int) {
        guard prepare(width: width, height: height) else { return }
        let t0 = Split.now()
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffers[packIndex])
        renderer.render(list, width: width, height: height)
        let t1 = Split.now()
        glPixelStorei(GLenum(GL_PACK_ALIGNMENT), 4)

        guard let mapBufferRange, let unmapBuffer, packBuffers[0] != 0 else {
            // No buffer to read into: ask for the pixels and wait for them.
            guard let staging else { return }
            glFinish()
            let t2 = Split.now()
            glReadPixels(0, 0, GLsizei(width), GLsizei(height),
                         readFormat, GLenum(GL_UNSIGNED_BYTE), staging)
            let t3 = Split.now()
            if let error = firstError() { log("screen: the GPU reported \(error)") }
            copy(from: staging.assumingMemoryBound(to: UInt32.self), into: pixels,
                 width: width, height: height, stride: stride)
            Split.add(submit: t1 - t0, flush: 0, draw: t2 - t1, read: t3 - t2,
                      copy: Split.now() - t3, width: width, height: height)
            return
        }

        // Ask for this frame and do not wait: a read into a pixel buffer
        // gives the order to the GPU and returns.
        let writing = packIndex
        glBindBuffer(CGLES_PIXEL_PACK_BUFFER, packBuffers[writing])
        glReadPixels(0, 0, GLsizei(width), GLsizei(height),
                     readFormat, GLenum(GL_UNSIGNED_BYTE), nil)
        glFlush()
        let tFlush = Split.now()

        // Take the frame before this one. The GPU has had a whole frame to
        // finish it, so nothing waits here. The first frame has nothing
        // behind it, and it is the one frame that waits for its own.
        let ready = packHasFrame ? 1 - writing : writing
        if !packHasFrame { glFinish() }
        let t2 = Split.now()
        glBindBuffer(CGLES_PIXEL_PACK_BUFFER, packBuffers[ready])
        let mapped = mapBufferRange(CGLES_PIXEL_PACK_BUFFER, 0, GLsizeiptr(packBytes),
                                    CGLES_MAP_READ_BIT)
        let t3 = Split.now()
        if let mapped {
            copy(from: mapped.assumingMemoryBound(to: UInt32.self), into: pixels,
                 width: width, height: height, stride: stride)
            _ = unmapBuffer(CGLES_PIXEL_PACK_BUFFER)
        } else {
            log("screen: the GPU gave no pixels back")
        }
        glBindBuffer(CGLES_PIXEL_PACK_BUFFER, 0)
        if let error = firstError() { log("screen: the GPU reported \(error)") }
        // The next frame goes into the other buffer, always. Leaving the
        // two the same for one turn made the frame after the first read a
        // buffer that nothing had written, which is black, and a shell that
        // then had nothing to draw left that black frame on the screen.
        packIndex = 1 - writing
        packHasFrame = true
        Split.add(submit: t1 - t0, flush: tFlush - t1, draw: t2 - tFlush,
                  read: t3 - t2, copy: Split.now() - t3,
                  width: width, height: height)
    }

    /// Puts a frame the GPU gave back into the buffer of the display.
    ///
    /// GL counts rows from the bottom of the picture and the display counts
    /// them from the top, so the rows change place. With GL_RGBA red and
    /// blue change place as well.
    private func copy(from source: UnsafeMutablePointer<UInt32>,
                      into pixels: UnsafeMutablePointer<UInt32>,
                      width: Int, height: Int, stride: Int) {
        let swapsRedAndBlue = readFormat == GLenum(GL_RGBA)
        for y in 0..<height {
            let from = source.advanced(by: (height - 1 - y) * width)
            let to = pixels.advanced(by: y * stride)
            if swapsRedAndBlue {
                for x in 0..<width {
                    let value = from[x]      // 0xAABBGGRR
                    to[x] = (value & 0xFF00_FF00)
                        | ((value & 0x00FF_0000) >> 16)
                        | ((value & 0x0000_00FF) << 16)
                }
            } else {
                to.update(from: from, count: width)
            }
        }
    }
}
