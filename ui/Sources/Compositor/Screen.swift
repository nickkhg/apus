import DRMKit
import Glibc
import Render

/// One output (monitor), double-buffered: we draw into the back buffer and
/// flip it to the front at the next vertical blank. Frames are drawn only
/// when something changed.
final class Screen: PageFlipHandler {
    let device: DRMDevice
    private(set) var output: Output
    var width: Int { output.mode.width }
    var height: Int { output.mode.height }
    /// The width of the picture on the monitor, in millimetres, or nil when
    /// the display does not say. A virtual display usually does not.
    var widthInMillimetres: Int? {
        output.widthInMillimetres > 0 ? output.widthInMillimetres : nil
    }

    /// Called to draw a frame.
    var draw: (Canvas) -> Void = { _ in }
    /// Called when a frame reached the screen (for Wayland frame callbacks).
    var frameShown: () -> Void = {}
    /// Called after the screen took a new size, so that the layout can run
    /// again.
    var sizeChanged: () -> Void = {}

    private var buffers: [DumbFramebuffer]
    private var back = 1
    private var flipPending = false
    private var needsFrame = false
    private var restore: ScreenRestore?
    /// Some drivers can't page flip; then frames are shown with a mode set.
    private var canPageFlip = true
    /// Set when the display reported a change. The new size is taken between
    /// frames, because a buffer that the screen is showing cannot go away.
    private var displayMayHaveChanged = false

    init(device: DRMDevice) throws(DRMError) {
        guard let output = try device.connectedOutputs().first else { throw .noDevice }
        self.device = device
        self.output = output
        let (w, h) = (output.mode.width, output.mode.height)
        buffers = [try DumbFramebuffer(device: device, width: w, height: h),
                   try DumbFramebuffer(device: device, width: w, height: h)]
        restore = try device.show(buffers[0], on: output)
    }

    /// The display reported a change: a monitor that a person connected, or
    /// a virtual screen that took a new size. The mode is read again, and
    /// the buffers follow it.
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
    var front: DumbFramebuffer { buffers[1 - back] }

    /// Puts back what was on screen before (the text console).
    func release() {
        restore?.restore()
        restore = nil
    }

    /// Asks for a new frame. Several requests before the next vertical blank
    /// produce one frame.
    func setNeedsFrame() {
        needsFrame = true
        if !flipPending { drawFrame() }
    }

    private func drawFrame() {
        needsFrame = false
        let buffer = buffers[back]
        buffer.withPixels { pixels, stride in
            draw(Canvas(pixels: pixels, width: width, height: height, stride: stride))
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
