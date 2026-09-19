import CDRM
import Glibc

/// Receives page-flip completions from DRMDevice.handleEvents().
public protocol PageFlipHandler: AnyObject {
    func pageFlipCompleted()
}

extension DRMDevice {
    /// Makes `framebuffer` current right away (a full mode set). Use once at
    /// start-up; after that, use schedulePageFlip.
    public func setFramebuffer(_ framebuffer: DumbFramebuffer, on output: Output) throws(DRMError) {
        var connector = output.connectorID
        var mode = output.mode.info
        guard drmModeSetCrtc(fd, output.crtcID, framebuffer.id, 0, 0, &connector, 1, &mode) == 0 else {
            throw .call("drmModeSetCrtc", errno: errno)
        }
    }

    /// Queues `framebuffer` to replace the current one at the next vertical
    /// blank. When the flip is done, the device fd becomes readable and
    /// handleEvents() calls handler.pageFlipCompleted().
    public func schedulePageFlip(_ framebuffer: DumbFramebuffer, on output: Output,
                                 handler: PageFlipHandler) throws(DRMError) {
        let userData = Unmanaged.passUnretained(handler as AnyObject).toOpaque()
        guard drmModePageFlip(fd, output.crtcID, framebuffer.id,
                              UInt32(DRM_MODE_PAGE_FLIP_EVENT), userData) == 0 else {
            throw .call("drmModePageFlip", errno: errno)
        }
    }

    /// Reads pending events from the device fd. Call when it's readable.
    public func handleEvents() {
        var context = drmEventContext(
            version: 2,
            vblank_handler: nil,
            page_flip_handler: { _, _, _, _, userData in
                guard let userData else { return }
                let object = Unmanaged<AnyObject>.fromOpaque(userData).takeUnretainedValue()
                (object as? PageFlipHandler)?.pageFlipCompleted()
            },
            page_flip_handler2: nil,
            sequence_handler: nil
        )
        drmHandleEvent(fd, &context)
    }
}
