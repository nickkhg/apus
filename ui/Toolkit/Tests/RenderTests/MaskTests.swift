import Render
import Testing

// A mask is the coverage of a filled path, for a GPU texture. The CPU
// renderer and the mask use one rasterizer, so a shape must have the same
// edges in both. These tests check that, because a difference would show as
// a shape that changes when the renderer changes.

/// Draws one path into a canvas with the CPU renderer, on black.
private func drawn(_ path: Path, width: Int, height: Int, color: UInt32) -> [UInt32] {
    var pixels = [UInt32](repeating: 0, count: width * height)
    pixels.withUnsafeMutableBufferPointer { buffer in
        SoftwareRenderer.render([.path(path, color: color)],
                                into: Canvas(pixels: buffer.baseAddress!, width: width,
                                             height: height, stride: width))
    }
    return pixels
}

private func square(x: Double, y: Double, side: Double) -> Path {
    var path = Path()
    path.addRectangle(x: x, y: y, width: side, height: side)
    return path
}

@Test("A mask covers the pixels that the path covers")
func maskBounds() throws {
    let path = square(x: 2, y: 3, side: 4)
    let mask = try #require(SoftwareRenderer.mask(
        for: path, clippedTo: Rect(x: 0, y: 0, width: 20, height: 20)))
    #expect(mask.x == 2)
    #expect(mask.y == 3)
    // The bounds round out, so the mask can be one pixel wider than the box.
    #expect(mask.width >= 4)
    #expect(mask.height >= 4)
    #expect(mask.coverage.count == mask.width * mask.height)
}

@Test("A whole pixel inside the path is fully covered, one outside is not")
func maskCoverage() throws {
    let path = square(x: 2, y: 2, side: 6)
    let mask = try #require(SoftwareRenderer.mask(
        for: path, clippedTo: Rect(x: 0, y: 0, width: 20, height: 20)))

    func coverage(x: Int, y: Int) -> UInt8 {
        mask.coverage[(y - mask.y) * mask.width + (x - mask.x)]
    }
    #expect(coverage(x: 4, y: 4) == 255)   // well inside
    #expect(coverage(x: 2, y: 2) == 255)   // the first whole pixel
}

@Test("The mask agrees with what the CPU renderer draws")
func maskMatchesRenderer() throws {
    // Round corners give partly covered pixels, which is where a second
    // rasterizer would disagree with the first one.
    var path = Path()
    path.addRoundedRectangle(x: 1.5, y: 2.25, width: 12, height: 9, radius: 3)

    let (width, height) = (20, 20)
    let pixels = drawn(path, width: width, height: height, color: 0xFFFFFFFF)
    let mask = try #require(SoftwareRenderer.mask(
        for: path, clippedTo: Rect(x: 0, y: 0, width: width, height: height)))

    // White on black: the red channel of a drawn pixel is its coverage.
    for row in 0..<mask.height {
        for column in 0..<mask.width {
            let drawnValue = UInt8((pixels[(mask.y + row) * width + mask.x + column] >> 16) & 0xFF)
            let maskValue = mask.coverage[row * mask.width + column]
            // Both round to a byte, from the same values, so they differ by
            // at most one step of rounding.
            #expect(abs(Int(drawnValue) - Int(maskValue)) <= 1,
                    "pixel (\(mask.x + column), \(mask.y + row))")
        }
    }
}
