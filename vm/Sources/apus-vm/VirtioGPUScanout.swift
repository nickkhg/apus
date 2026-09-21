import CoreGraphics
import Foundation
import Virtualization

/// A picture that the guest draws and asks the device to show.
///
/// The guest keeps the pixels in its own memory and tells the device which
/// pages they are in. A transfer copies a part of those pages into the
/// buffer here, and a flush shows it. The copy is what the specification
/// asks for: the guest may write its pages at any time, and only a transfer
/// says that a part of them is ready.
@available(macOS 27, *)
final class Resource2D {
    let width: Int
    let height: Int
    /// The bytes of the picture, four to a pixel, width * height of them.
    let pixels: UnsafeMutableRawPointer
    let byteCount: Int
    /// The guest pages that hold the same picture, in order.
    private var backing: [VZGuestMemoryMapping] = []

    var bytesPerRow: Int { width * 4 }

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        byteCount = self.width * self.height * 4
        pixels = .allocate(byteCount: byteCount, alignment: 16)
        pixels.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
    }

    deinit { pixels.deallocate() }

    func attach(_ pages: [VZGuestMemoryMapping]) { backing = pages }
    func detach() { backing = [] }

    /// Copies a rectangle of the guest's pages into the buffer here.
    ///
    /// `offset` is where the rectangle starts in the picture, counted in
    /// bytes from its first pixel. The guest lays a picture out row by row,
    /// so a rectangle is a run of bytes in each of its rows.
    func transfer(_ rectangle: VirtioGPU.Rectangle, from offset: UInt64) {
        guard !backing.isEmpty else { return }
        let left = Int(rectangle.x), top = Int(rectangle.y)
        let across = min(Int(rectangle.width), width - left)
        let down = min(Int(rectangle.height), height - top)
        guard across > 0, down > 0, left >= 0, top >= 0 else { return }

        for row in 0..<down {
            let from = Int(offset) + row * bytesPerRow
            let to = (top + row) * bytesPerRow + left * 4
            guard to + across * 4 <= byteCount else { return }
            read(from: from, into: pixels.advanced(by: to), count: across * 4)
        }
    }

    /// Reads `count` bytes that start `from` bytes into the guest's pages.
    /// The pages are one picture, so a run of bytes can cross a page.
    private func read(from start: Int, into destination: UnsafeMutableRawPointer, count: Int) {
        var wanted = start
        var left = count
        var out = destination
        for page in backing {
            let length = page.length
            if wanted >= length { wanted -= length; continue }
            let take = min(left, length - wanted)
            out.copyMemory(from: page.mutableBytes.advanced(by: wanted), byteCount: take)
            out = out.advanced(by: take)
            left -= take
            wanted = 0
            if left == 0 { return }
        }
    }

    /// The picture as a CGImage, for the window to draw.
    ///
    /// The guest writes B8G8R8X8, which on a little-endian machine is one
    /// 32-bit word per pixel with the blue byte first. That is what
    /// `byteOrder32Little` with `noneSkipFirst` names.
    func image(opaque: Bool = true) -> CGImage? {
        guard let provider = CGDataProvider(
            dataInfo: nil, data: pixels, size: byteCount, releaseData: { _, _, _ in })
        else { return nil }
        // The screen has nothing behind it, so its alpha means nothing. The
        // picture of a pointer has a shape, and the alpha is the shape.
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipFirst : .premultipliedFirst
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue).union(.byteOrder32Little),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }
}

/// Where the pictures of the device go. The window sets this; with no
/// window the device still keeps the pictures, and draws nothing.
@available(macOS 27, *)
protocol GuestScreen: AnyObject, Sendable {
    /// Called on the queue of the device, once for each flush.
    func show(_ image: CGImage)

    /// The pointer changed. `image` is its picture, or nil to hide it, and
    /// the place is the top left corner of that picture on the screen.
    ///
    /// The pointer is not in the frame. A display draws it over the frame
    /// from a plane of its own, and the guest moves it with the second
    /// queue of the device, which costs no frame. The window does the same
    /// with a layer of its own.
    func showCursor(_ image: CGImage?, atX x: Int, y: Int)
}

@available(macOS 27, *)
extension GuestScreen {
    /// A screen that has no pointer of its own ignores it.
    func showCursor(_ image: CGImage?, atX x: Int, y: Int) {}
}
