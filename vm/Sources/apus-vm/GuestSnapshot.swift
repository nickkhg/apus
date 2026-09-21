import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
