import AppKit
import CoreGraphics
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// Shows the pictures of the virtio-gpu device that this program makes.
///
/// The view sits over `VZVirtualMachineView`, which stays for the keyboard
/// and the pointer: those are USB devices of the framework, and that view
/// is what carries events to them. This view takes no events of its own, so
/// a click goes through it to the view below.
@available(macOS 27, *)
final class GuestView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
        // Nothing drives this device until a program in the guest asks for
        // it. Until then the view stays out of the way, and the window
        // shows the graphics device of the framework below.
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    /// Events belong to the view below.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Carries a picture from the queue of the device to the window.
///
/// The device calls `show` on its own queue, and AppKit wants the main one,
/// so the picture crosses over here. A picture that arrives while another
/// one waits replaces it: the window shows the newest, and a slow window
/// slows nothing down in the guest.
@available(macOS 27, *)
final class GuestDisplay: GuestScreen, @unchecked Sendable {
    private let layer: CALayer
    private let lock = NSLock()
    private var pending: CGImage?
    /// Run once, on the main thread, when the first picture arrives. The
    /// view is hidden until then.
    private var onFirst: (() -> Void)?

    init(layer: CALayer, onFirst: (() -> Void)? = nil) {
        self.layer = layer
        self.onFirst = onFirst
    }

    func show(_ image: CGImage) {
        lock.lock()
        let first = pending == nil
        pending = image
        lock.unlock()
        guard first else { return }
        DispatchQueue.main.async { [self] in
            lock.lock()
            let image = pending
            pending = nil
            lock.unlock()
            // A picture of the guest has no animation of its own: without
            // this, each one fades into the last.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = image
            CATransaction.commit()
            onFirst?()
            onFirst = nil
        }
    }
}

/// Writes each picture of the guest to a PNG file.
///
/// Virtualization has no screenshot of its own, and the tests therefore
/// read the screen inside the guest. With a device of our own the host
/// holds the pixels, so it can write them. VM_SNAPSHOT names the file, and
/// every flush replaces it.
@available(macOS 27, *)
final class GuestSnapshot: GuestScreen, @unchecked Sendable {
    private let path: String
    private let next: (any GuestScreen)?

    init(path: String, then next: (any GuestScreen)? = nil) {
        self.path = path
        self.next = next
    }

    func show(_ image: CGImage) {
        next?.show(image)
        // The file is written beside the one it replaces and then moved, so
        // a reader never sees half a picture.
        let temporary = path + ".part"
        guard let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: temporary) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.moveItem(atPath: temporary, toPath: path)
    }
}
