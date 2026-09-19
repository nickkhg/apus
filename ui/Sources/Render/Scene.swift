// The screen is drawn from a display list: a flat, back-to-front list of
// drawing items. Window contents, the cursor and the shell's own UI all
// become items. The renderer is the only code that writes pixels, so a GPU
// renderer can replace SoftwareRenderer and nothing above it changes.
//
// This module is the bottom of the UI stack. The Toolkit module makes
// display lists from views, and the Compositor module composites windows.

/// A rectangle in screen pixels.
public struct Rect: Sendable, Equatable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
    }
}

/// An image in memory: 32-bit pixels, 0xAARRGGBB, alpha premultiplied.
/// If `isOpaque`, the alpha byte is ignored.
public final class Bitmap {
    public let width: Int
    public let height: Int
    public let isOpaque: Bool
    public var pixels: [UInt32]

    public init(width: Int, height: Int, isOpaque: Bool, pixels: [UInt32]) {
        precondition(pixels.count == width * height)
        (self.width, self.height, self.isOpaque, self.pixels) = (width, height, isOpaque, pixels)
    }
}

public enum DisplayItem {
    /// A solid colour, 0xRRGGBB.
    case fill(Rect, color: UInt32)
    /// A bitmap with its top-left corner at (x, y).
    case bitmap(Bitmap, x: Int, y: Int)
}

public typealias DisplayList = [DisplayItem]

/// Where the renderer draws: 32-bit XRGB pixels, `stride` pixels per row.
public struct Canvas {
    public let pixels: UnsafeMutablePointer<UInt32>
    public let width: Int
    public let height: Int
    public let stride: Int

    public init(pixels: UnsafeMutablePointer<UInt32>, width: Int, height: Int, stride: Int) {
        (self.pixels, self.width, self.height, self.stride) = (pixels, width, height, stride)
    }
}

/// Draws display lists with the CPU.
public enum SoftwareRenderer {
    public static func render(_ list: DisplayList, into canvas: Canvas) {
        for item in list {
            switch item {
            case .fill(let rect, let color):
                fill(rect, color: color, canvas)
            case .bitmap(let bitmap, let x, let y):
                draw(bitmap, x: x, y: y, canvas)
            }
        }
    }

    private static func fill(_ rect: Rect, color: UInt32, _ canvas: Canvas) {
        let x0 = max(0, rect.x), x1 = min(canvas.width, rect.x + rect.width)
        let y0 = max(0, rect.y), y1 = min(canvas.height, rect.y + rect.height)
        guard x0 < x1, y0 < y1 else { return }
        for row in y0..<y1 {
            UnsafeMutableBufferPointer(start: canvas.pixels + row * canvas.stride + x0, count: x1 - x0)
                .update(repeating: color)
        }
    }

    private static func draw(_ bitmap: Bitmap, x: Int, y: Int, _ canvas: Canvas) {
        // Visible part, in bitmap coordinates.
        let left = max(0, -x), right = min(bitmap.width, canvas.width - x)
        let top = max(0, -y), bottom = min(bitmap.height, canvas.height - y)
        guard left < right, top < bottom else { return }
        let count = right - left

        bitmap.pixels.withUnsafeBufferPointer { source in
            for row in top..<bottom {
                let src = source.baseAddress! + row * bitmap.width + left
                let dst = canvas.pixels + (y + row) * canvas.stride + x + left
                if bitmap.isOpaque {
                    dst.update(from: src, count: count)
                } else {
                    for i in 0..<count { dst[i] = blend(src[i], over: dst[i]) }
                }
            }
        }
    }

    /// Source-over for premultiplied alpha: out = src + dst × (1 − αsrc).
    @inline(__always)
    private static func blend(_ src: UInt32, over dst: UInt32) -> UInt32 {
        let alpha = src >> 24
        if alpha == 0xFF { return src }
        if alpha == 0 { return dst }
        let inverse = 255 - alpha
        // Red and blue together, then green, 8 bits of headroom each.
        let rb = ((dst & 0xFF00FF) * inverse >> 8) & 0xFF00FF
        let g = ((dst & 0x00FF00) * inverse >> 8) & 0x00FF00
        return (src & 0xFFFFFF) &+ rb &+ g
    }
}
