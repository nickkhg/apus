import Render
import Testing

// Source-over with premultiplied alpha: out = src + dst × (1 − αsrc).
//
// A partly transparent colour must let the destination show through. It did
// not: the blend multiplied the destination by `inverse >> 8`, which is
// always 0, so every translucent item covered what was under it instead of
// blending with it. These tests hold the arithmetic.

private let width = 8
private let height = 8

/// Draws items over an opaque background and gives one pixel as (r, g, b).
private func pixel(_ items: [DisplayItem], background: UInt32,
                   x: Int = 4, y: Int = 4) -> (Int, Int, Int) {
    var pixels = [UInt32](repeating: 0, count: width * height)
    pixels.withUnsafeMutableBufferPointer { buffer in
        SoftwareRenderer.render(
            [.fill(Rect(x: 0, y: 0, width: width, height: height), color: background)] + items,
            into: Canvas(pixels: buffer.baseAddress!, width: width, height: height, stride: width))
    }
    let value = pixels[y * width + x]
    return (Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF))
}

private let whole = Rect(x: 0, y: 0, width: width, height: height)

/// 0x1B1626 at 0.85, premultiplied. This is the background of the dock.
private let translucent: UInt32 = 0xD9171320
private let background: UInt32 = 0xFF2B2340   // the desktop

/// src + dst × (1 − 217/255) = (23, 19, 32) + (43, 35, 64) × 0.149.
/// The renderer divides by 256 rather than 255, so it can be one lower.
private func near(_ actual: (Int, Int, Int), _ expected: (Int, Int, Int)) -> Bool {
    abs(actual.0 - expected.0) <= 1 && abs(actual.1 - expected.1) <= 1
        && abs(actual.2 - expected.2) <= 1
}

@Test("A translucent rectangle lets the background through")
func translucentRectangle() {
    let result = pixel([.fill(whole, color: translucent)], background: background)
    #expect(near(result, (29, 24, 41)), "got \(result)")
}

@Test("A translucent path lets the background through")
func translucentPath() {
    var path = Path()
    path.addRectangle(x: 0, y: 0, width: Double(width), height: Double(height))
    let result = pixel([.path(path, color: translucent)], background: background)
    #expect(near(result, (29, 24, 41)), "got \(result)")
}

@Test("A translucent bitmap lets the background through")
func translucentBitmap() {
    let bitmap = Bitmap(width: width, height: height, isOpaque: false,
                        pixels: [UInt32](repeating: translucent, count: width * height))
    let result = pixel([.bitmap(bitmap, x: 0, y: 0)], background: background)
    #expect(near(result, (29, 24, 41)), "got \(result)")
}

@Test("An opaque colour covers the background")
func opaqueCovers() {
    let result = pixel([.fill(whole, color: 0xFF3070F0)], background: background)
    #expect(result == (0x30, 0x70, 0xF0), "got \(result)")
}

@Test("A colour with no alpha leaves the background")
func emptyKeeps() {
    let result = pixel([.fill(whole, color: 0x00000000)], background: background)
    #expect(result == (0x2B, 0x23, 0x40), "got \(result)")
}

@Test("Half alpha lands between the two colours")
func halfWay() {
    // White at half alpha over black: about half white.
    let result = pixel([.fill(whole, color: 0x80808080)], background: 0xFF000000)
    #expect(near(result, (128, 128, 128)), "got \(result)")
}
