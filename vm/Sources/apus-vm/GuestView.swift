import AppKit
import CoreGraphics

/// The screen of the guest, drawn from the pictures of our own virtio-gpu
/// device.
///
/// The window holds two graphics devices. The framework's device is a 2D
/// scanout with no 3D at all, and `VZVirtualMachineView` draws it. Our
/// device carries the GPU of the Mac, and the framework draws nothing for
/// it, so this view draws it.
///
/// The view sits over the view of the framework and takes no events. The
/// view below it keeps the keyboard and the pointer.
///
/// The pointer is a layer of its own, over the picture. The guest moves it
/// with the cursor queue of the device, which draws no frame, and
/// CoreAnimation puts it over the picture here. So a move of the mouse
/// costs no frame on either side.
@available(macOS 27, *)
@MainActor
final class GuestView: NSView {
    /// The pointer, over the picture.
    private let cursorLayer = CALayer()
    /// The size of the screen of the guest, in the pixels of the guest. The
    /// view is often another size, and the picture scales to fit it.
    private var guestSize = CGSize(width: 1, height: 1)
    /// Where the top left corner of the pointer is, in those same pixels.
    private var cursorAt = CGPoint.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // The guest draws every pixel of its screen. A window of another
        // shape shows black at the sides, and the picture keeps its shape.
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .trilinear

        cursorLayer.isHidden = true
        // The pointer is placed by its top left corner, as the guest places
        // it, and not by its middle.
        cursorLayer.anchorPoint = .zero
        cursorLayer.magnificationFilter = .nearest
        layer?.addSublayer(cursorLayer)
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { true }
    /// The guest counts rows from the top, so this view does too. The layers
    /// then take the places that the guest gives, with no arithmetic.
    override var isFlipped: Bool { true }

    /// Events belong to the view below, which sends them to the machine.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeCursor()
    }

    /// A new frame from the guest.
    func show(_ image: CGImage) {
        guestSize = CGSize(width: image.width, height: image.height)
        // The layer holds the picture, and CoreAnimation draws it on the
        // next pass of the window server. There is no drawRect here.
        layer?.contents = image
        placeCursor()
    }

    /// The pointer changed. `image` is nil when the guest wants none.
    func showCursor(_ image: CGImage?, atX x: Int, y: Int) {
        cursorAt = CGPoint(x: x, y: y)
        guard let image else {
            cursorLayer.isHidden = true
            return
        }
        // A layer animates a change of position by default, which for a
        // pointer means a pointer that slides after the mouse.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if cursorLayer.contents == nil || cursorLayer.bounds.width != Double(image.width)
            || cursorLayer.bounds.height != Double(image.height) {
            cursorLayer.bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        }
        cursorLayer.contents = image
        cursorLayer.isHidden = false
        placeCursor()
        CATransaction.commit()
    }

    /// Puts the pointer where the picture puts it. The picture fills the
    /// view and keeps its shape, so the pointer takes the same scale and
    /// the same margin.
    private func placeCursor() {
        guard guestSize.width > 0, guestSize.height > 0 else { return }
        let size = bounds.size
        let scale = min(size.width / guestSize.width, size.height / guestSize.height)
        let margin = CGPoint(x: (size.width - guestSize.width * scale) / 2,
                             y: (size.height - guestSize.height * scale) / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.transform = CATransform3DMakeScale(scale, scale, 1)
        cursorLayer.position = CGPoint(x: margin.x + cursorAt.x * scale,
                                       y: margin.y + cursorAt.y * scale)
        CATransaction.commit()
    }
}

/// Gives the pictures of the device to a view, on the main thread.
///
/// The device calls these from the queue it reads its commands on. A flush
/// must not wait for the window, so the picture goes to the main thread and
/// the device answers the guest at once.
///
/// One picture waits at a time. A guest that draws faster than the window
/// shows replaces the waiting picture, so the window never falls behind.
@available(macOS 27, *)
final class GuestWindowScreen: GuestScreen, @unchecked Sendable {
    private let view: GuestView
    private let lock = NSLock()
    private var waiting: CGImage?
    private var isScheduled = false

    init(view: GuestView) {
        self.view = view
    }

    func show(_ image: CGImage) {
        // The bytes of the picture are the buffer of the resource, and the
        // next transfer writes that buffer again. CoreAnimation reads the
        // picture after this call gives the guest its answer, so the picture
        // takes a copy. SET_SCANOUT_BLOB takes this copy away: the guest
        // then draws into memory that the Mac already holds.
        guard let copy = image.withBytesOfItsOwn() else { return }
        let start: Bool = lock.withLock {
            waiting = copy
            guard !isScheduled else { return false }
            isScheduled = true
            return true
        }
        guard start else { return }
        DispatchQueue.main.async { [self] in
            let next: CGImage? = lock.withLock {
                isScheduled = false
                defer { waiting = nil }
                return waiting
            }
            guard let next else { return }
            MainActor.assumeIsolated { view.show(next) }
        }
    }

    func showCursor(_ image: CGImage?, atX x: Int, y: Int) {
        // The picture of a pointer is small, and it changes almost never.
        let copy = image?.withBytesOfItsOwn()
        DispatchQueue.main.async { [view] in
            MainActor.assumeIsolated { view.showCursor(copy, atX: x, y: y) }
        }
    }
}

extension CGImage {
    /// The same picture with bytes of its own, so that the writer of the
    /// first one can write them again.
    func withBytesOfItsOwn() -> CGImage? {
        guard let data = dataProvider?.data, let provider = CGDataProvider(data: data) else {
            return nil
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel, bytesPerRow: bytesPerRow,
            space: colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: renderingIntent)
    }
}
