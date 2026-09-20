import Render

/// The pointer: a classic arrow, drawn at the pointer position.
enum Cursor {
    /// Hotspot is the top-left pixel. X = outline, o = fill, space = clear.
    private static let shape = [
        "X",
        "XX",
        "XoX",
        "XooX",
        "XoooX",
        "XooooX",
        "XoooooX",
        "XooooooX",
        "XoooooooX",
        "XooooooooX",
        "XoooooooooX",
        "XooooooXXXXX",
        "XoooXooX",
        "XooXXooX",
        "XoX  XooX",
        "XX   XooX",
        "X     XooX",
        "      XooX",
        "       XX",
    ]

    // Built once, never mutated, used only on the compositor thread.
    nonisolated(unsafe) static let bitmap: Bitmap = {
        let width = shape.map(\.count).max()!
        var pixels = [UInt32](repeating: 0, count: width * shape.count)
        for (y, line) in shape.enumerated() {
            for (x, character) in line.enumerated() {
                switch character {
                case "X": pixels[y * width + x] = 0xFF00_0000   // opaque black
                case "o": pixels[y * width + x] = 0xFFFF_FFFF   // opaque white
                default: break                                  // transparent
                }
            }
        }
        return Bitmap(width: width, height: shape.count, isOpaque: false, pixels: pixels)
    }()
}

extension Cursor {
    /// The pointer at `scale` pixels to the point. A whole number of pixels
    /// for each one keeps the edges sharp, which a smooth scale would not.
    /// The result is kept, because the scale rarely changes.
    static func bitmap(scale: Int) -> Bitmap {
        guard scale > 1 else { return bitmap }
        if let cached = cache.value, cached.scale == scale { return cached.bitmap }
        let source = bitmap
        let width = source.width * scale
        let height = source.height * scale
        var pixels = [UInt32](repeating: 0, count: width * height)
        for row in 0..<height {
            let sourceRow = (row / scale) * source.width
            for column in 0..<width {
                pixels[row * width + column] = source.pixels[sourceRow + column / scale]
            }
        }
        let scaled = Bitmap(width: width, height: height, isOpaque: false, pixels: pixels)
        cache.value = (scale, scaled)
        return scaled
    }

    private final class Cache: @unchecked Sendable {
        var value: (scale: Int, bitmap: Bitmap)?
    }

    nonisolated(unsafe) private static let cache = Cache()
}
