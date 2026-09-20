import DRMKit
import Glibc
import Render

/// One output (monitor), double-buffered: we draw into the back buffer and
/// flip it to the front at the next vertical blank. Frames are drawn only
/// when something changed.
final class Screen: PageFlipHandler {
    let device: DRMDevice
    let output: Output
    var width: Int { output.mode.width }
    var height: Int { output.mode.height }

    /// Called to draw a frame.
    var draw: (Canvas) -> Void = { _ in }
    /// Called when a frame reached the screen (for Wayland frame callbacks).
    var frameShown: () -> Void = {}

    private var buffers: [DumbFramebuffer]
    private var back = 1
    private var flipPending = false
    private var needsFrame = false
    private var restore: ScreenRestore?
    /// Some drivers can't page flip; then frames are shown with a mode set.
    private var canPageFlip = true

    init(device: DRMDevice) throws(DRMError) {
        guard let output = try device.connectedOutputs().first else { throw .noDevice }
        self.device = device
        self.output = output
        let (w, h) = (output.mode.width, output.mode.height)
        buffers = [try DumbFramebuffer(device: device, width: w, height: h),
                   try DumbFramebuffer(device: device, width: w, height: h)]
        restore = try device.show(buffers[0], on: output)
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
        if needsFrame { drawFrame() }
    }
}
