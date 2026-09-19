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
