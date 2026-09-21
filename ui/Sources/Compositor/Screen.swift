import DRMKit
import Glibc
import Render

/// One output (monitor). The compositor gives it a display list and asks for
/// a frame; how the pixels are made is the screen's business.
///
/// SoftwareScreen draws with the CPU into dumb buffers. GPUScreen draws with
/// GLES into GBM buffers. `APUS_RENDERER` chooses between them.
protocol Screen: AnyObject {
    var output: Output { get }
    var width: Int { get }
    var height: Int { get }
    var widthInMillimetres: Int? { get }
    /// Whether a GPU draws the frames. The shell asks, because it holds
    /// different values for depth in each mode (see Theme.swift).
    var usesGPU: Bool { get }

    /// The items to draw. The screen asks for them when it draws a frame.
    var displayList: () -> DisplayList { get set }
    /// Called when a frame reached the screen (for Wayland frame callbacks).
    var frameShown: () -> Void { get set }
    /// Called after the screen took a new size, so that the layout can run
    /// again.
    var sizeChanged: () -> Void { get set }

    /// Asks for a new frame. Several requests before the next vertical blank
    /// produce one frame.
    func setNeedsFrame()
    /// The display reported a change: a monitor that a person connected, or
    /// a virtual screen that took a new size.
    func displayChanged()
    /// Puts back what was on screen before (the text console).
    func release()
    /// Writes the pixels that the screen shows now, as a binary PPM. The
    /// tests read the file.
    func writePicture(to path: String) throws
}

/// Turns a display list into pixels. The screen owns the buffers and the
/// display; this makes the picture that goes in them.
///
/// The CPU rasterizer draws with SoftwareRenderer. The offscreen one draws
/// with the GPU and reads the frame back. GPUScreen has neither, because
/// there the GPU draws into the buffer that the display reads.
protocol FrameRasterizer: AnyObject {
    /// Whether a GPU draws the frames. The shell asks, because it holds
    /// different values for depth in each mode (see Theme.swift).
    var usesGPU: Bool { get }
    /// For the frame times of APUS_FRAME_LOG.
    var name: String { get }

    func render(_ list: DisplayList, into pixels: UnsafeMutablePointer<UInt32>,
                width: Int, height: Int, stride: Int)
}

/// Draws with the CPU. Its pixels are the same on every run, which is what
/// the tests check.
final class CPURasterizer: FrameRasterizer {
    let usesGPU = false
    let name = "cpu"

    func render(_ list: DisplayList, into pixels: UnsafeMutablePointer<UInt32>,
                width: Int, height: Int, stride: Int) {
        SoftwareRenderer.render(list, into: Canvas(pixels: pixels, width: width,
                                                  height: height, stride: stride))
    }
}

/// The screen that `APUS_RENDERER` asks for. The default is the CPU,
/// because its pixels are the same on every run and the tests check exact
/// colours.
///
/// `gpu` draws through GBM, which is how a compositor normally reaches the
/// display. That needs a driver that can export a dma-buf, and a virtual
/// machine on a Mac has none, so `gpu` falls back to drawing offscreen and
/// reading each frame back. `offscreen` asks for that way from the start.
/// See docs/gpu.md.
func makeScreen(device: DRMDevice) throws -> any Screen {
    let wanted = getenv("APUS_RENDERER").map { String(cString: $0) } ?? "cpu"
    switch wanted {
    case "cpu", "software":
        return try SoftwareScreen(device: device)
    case "gpu", "gl":
        do {
            return try GPUScreen(device: device)
        } catch {
            log("screen: the GPU cannot draw straight into the display "
                + "(\(error)); drawing offscreen instead")
        }
        do {
            return try SoftwareScreen(device: device, rasterizer: OffscreenRasterizer())
        } catch {
            log("screen: no GPU draws here (\(error)); using the CPU")
            return try SoftwareScreen(device: device)
        }
    case "offscreen":
        return try SoftwareScreen(device: device, rasterizer: OffscreenRasterizer())
    default:
        log("screen: APUS_RENDERER must be 'cpu', 'gpu' or 'offscreen', "
            + "not '\(wanted)'; using cpu")
        return try SoftwareScreen(device: device)
    }
}

/// Draws into dumb buffers, double-buffered: we draw into the back buffer
/// and flip it to the front at the next vertical blank. Frames are drawn
/// only when something changed.
///
/// The rasterizer makes the picture. With the CPU one this is the whole of
/// the software path. With the offscreen one the GPU draws the frame and
/// the screen still owns the buffers and the flips.
final class SoftwareScreen: Screen, PageFlipHandler {
    var usesGPU: Bool { rasterizer.usesGPU }
    private let rasterizer: any FrameRasterizer

    let device: DRMDevice
    private(set) var output: Output
    var width: Int { output.mode.width }
    var height: Int { output.mode.height }
    /// The width of the picture on the monitor, in millimetres, or nil when
    /// the display does not say. A virtual display usually does not.
    var widthInMillimetres: Int? {
        output.widthInMillimetres > 0 ? output.widthInMillimetres : nil
    }

    var displayList: () -> DisplayList = { [] }
    var frameShown: () -> Void = {}
    var sizeChanged: () -> Void = {}

    private var buffers: [DumbFramebuffer]
    private var back = 1
    private var flipPending = false
    private var needsFrame = false
    private var restore: ScreenRestore?
    /// Some drivers can't page flip; then frames are shown with a mode set.
    private var canPageFlip = true
    /// True while a frame is being drawn.
    private var isDrawing = false
    private var timer: FrameTimer
    /// Set when the display reported a change. The new size is taken between
    /// frames, because a buffer that the screen is showing cannot go away.
    private var displayMayHaveChanged = false

    init(device: DRMDevice, rasterizer: any FrameRasterizer = CPURasterizer())
        throws(DRMError)
    {
        guard let output = try device.connectedOutputs().first else { throw .noDevice }
        self.device = device
        self.output = output
        self.rasterizer = rasterizer
        self.timer = FrameTimer(name: rasterizer.name)
        let (w, h) = (output.mode.width, output.mode.height)
        buffers = [try DumbFramebuffer(device: device, width: w, height: h),
                   try DumbFramebuffer(device: device, width: w, height: h)]
        restore = try device.show(buffers[0], on: output)
    }

    /// The mode is read again, and the buffers follow it.
    func displayChanged() {
        displayMayHaveChanged = true
        if !flipPending { takeNewMode() }
    }

    /// Reads the mode of the display again and makes buffers of that size.
    /// A buffer that the kernel is showing is never freed here, because this
    /// runs only when no flip is waiting.
    private func takeNewMode() {
        displayMayHaveChanged = false
        guard let outputs = try? device.connectedOutputs() else { return }
        // The same connector, or the first one that is left if it went away.
        guard let latest = outputs.first(where: { $0.connectorID == output.connectorID })
                ?? outputs.first else { return }
        guard latest.mode.width != width || latest.mode.height != height else { return }

        let (w, h) = (latest.mode.width, latest.mode.height)
        guard let first = try? DumbFramebuffer(device: device, width: w, height: h),
              let second = try? DumbFramebuffer(device: device, width: w, height: h) else {
            log("screen: no buffers for \(latest.mode)")
            return
        }
        log("SCREEN-MODE \(latest.mode)")
        output = latest
        buffers = [first, second]
        back = 1
        try? device.setFramebuffer(buffers[0], on: output)
        sizeChanged()
        setNeedsFrame()
    }

    /// The buffer that the screen shows now. The tests read these pixels:
    /// they are the ones that went to the display, not a second rendering.
    private var front: DumbFramebuffer { buffers[1 - back] }

    func writePicture(to path: String) throws {
        try front.writePPM(to: path)
    }

    func release() {
        restore?.restore()
        restore = nil
    }

    func setNeedsFrame() {
        needsFrame = true
        // A frame that is being drawn must not start another one. Something
        // that moves asks for the next frame while this one is drawn, and
        // the flip that follows picks it up.
        if !flipPending, !isDrawing { drawFrame() }
    }

    private func drawFrame() {
        isDrawing = true
        timer.began()
        defer { isDrawing = false; timer.ended(width: width, height: height) }
        needsFrame = false
        let buffer = buffers[back]
        let list = displayList()
        buffer.withPixels { pixels, stride in
            rasterizer.render(list, into: pixels, width: width, height: height,
                              stride: stride)
        }
        if canPageFlip {
            do {
                try device.schedulePageFlip(buffer, on: output, handler: self)
                flipPending = true
                return
            } catch {
                log("screen: page flip not available (\(error)); using mode sets")
                canPageFlip = false
            }
        }
        try? device.setFramebuffer(buffer, on: output)
        pageFlipCompleted()
    }

    func pageFlipCompleted() {
        flipPending = false
        back = 1 - back
        frameShown()
        // The old buffers are free now, so a new size can be taken.
        if displayMayHaveChanged { takeNewMode() }
        if needsFrame { drawFrame() }
    }
}
