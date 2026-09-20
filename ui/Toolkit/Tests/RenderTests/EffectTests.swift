import Render
import Testing

// A shadow, a blur and a gradient, drawn by the CPU renderer.
//
// The shell asks for these three in GPU mode only, but both renderers draw
// them: the display list says what the screen holds, not which renderer is
// behind it. These tests hold what each item means, and the GPU renderer
// draws the same items from the same masks.

private let width = 40
private let height = 40

/// Draws a list over an opaque background and gives back every pixel.
private func picture(_ items: [DisplayItem], background: UInt32 = 0xFF00_0000) -> [UInt32] {
    var pixels = [UInt32](repeating: 0, count: width * height)
    pixels.withUnsafeMutableBufferPointer { buffer in
        SoftwareRenderer.render(
            [.fill(Rect(x: 0, y: 0, width: width, height: height), color: background)] + items,
            into: Canvas(pixels: buffer.baseAddress!, width: width, height: height, stride: width))
    }
    return pixels
}

private func red(_ pixels: [UInt32], _ x: Int, _ y: Int) -> Int {
    Int((pixels[y * width + x] >> 16) & 0xFF)
}

private func green(_ pixels: [UInt32], _ x: Int, _ y: Int) -> Int {
    Int((pixels[y * width + x] >> 8) & 0xFF)
}

/// A square in the middle of the picture.
private func square(x: Double = 12, y: Double = 12,
                    width side: Double = 16, height: Double = 16) -> Path {
    var path = Path()
    path.addRectangle(x: x, y: y, width: side, height: height)
    return path
}

@Suite("A shadow")
struct ShadowTests {
    @Test("It reaches outside the shape and fades as it goes")
    func itFades() {
        // A white background, so that a dark shadow lowers the value.
        let shadow = Shadow(color: 0xFF00_0000, radius: 6)
        let pixels = picture([.shadow(square(), shadow)], background: 0xFFFF_FFFF)

        let middle = red(pixels, 20, 20)
        let edge = red(pixels, 10, 20)       // two pixels outside the shape
        let far = red(pixels, 2, 20)         // outside the reach of the shadow
        #expect(middle < 40, "the middle of a shadow is dark, got \(middle)")
        #expect(edge > middle && edge < 250, "the edge is between, got \(edge)")
        #expect(far == 255, "the shadow reaches too far, got \(far)")
    }

    @Test("It goes where the offset puts it")
    func itMovesWithTheOffset() {
        let shadow = Shadow(color: 0xFF00_0000, radius: 4, dy: 8)
        let pixels = picture([.shadow(square(), shadow)], background: 0xFFFF_FFFF)
        // The shape is 12 to 28. The shadow is 8 lower, so the pixels under
        // the shape are darker than the ones over it.
        #expect(red(pixels, 20, 32) < red(pixels, 20, 8))
    }

    @Test("A shadow with no alpha draws nothing")
    func nothingToDraw() {
        let pixels = picture([.shadow(square(), Shadow(color: 0, radius: 8))],
                             background: 0xFFFF_FFFF)
        #expect(pixels.allSatisfy { $0 == 0xFFFF_FFFF })
    }

    @Test("The mask is larger than the shape, because the edge is soft")
    func theMaskGrows() {
        let clip = Rect(x: 0, y: 0, width: width, height: height)
        let shadow = Shadow(color: 0xFF00_0000, radius: 6)
        let mask = SoftwareRenderer.shadowMask(for: square(), shadow, clippedTo: clip)
        let plain = SoftwareRenderer.mask(for: square(), clippedTo: clip)
        #expect(mask != nil && plain != nil)
        #expect(mask!.width > plain!.width)
        #expect(mask!.height > plain!.height)
    }
}

@Suite("A blur")
struct BlurTests {
    /// Half the picture is white and half is black, with the edge down the
    /// middle. A blur over the edge mixes the two sides.
    private func sides() -> [DisplayItem] {
        [.fill(Rect(x: 0, y: 0, width: width, height: height), color: 0xFFFF_FFFF),
         .fill(Rect(x: 20, y: 0, width: 20, height: height), color: 0xFF00_0000)]
    }

    @Test("It mixes the pixels that are beside each other")
    func itMixes() {
        let pixels = picture(sides() + [.blur(square(x: 8, y: 8, width: 24, height: 24),
                                              radius: 8)])
        // Just inside the white side, the blur has brought some black in.
        let white = red(pixels, 18, 20)
        let black = red(pixels, 22, 20)
        #expect(white < 255 && white > 60, "the white side did not mix, got \(white)")
        #expect(black > 0 && black < 200, "the black side did not mix, got \(black)")
    }

    @Test("It changes nothing outside its shape")
    func itStaysInside() {
        let pixels = picture(sides() + [.blur(square(x: 8, y: 8, width: 24, height: 24),
                                              radius: 8)])
        #expect(red(pixels, 2, 2) == 255)
        #expect(red(pixels, 38, 38) == 0)
    }

    @Test("A blur of no radius changes nothing")
    func noRadius() {
        let plain = picture(sides())
        let blurred = picture(sides() + [.blur(square(), radius: 0)])
        #expect(plain == blurred)
    }

    @Test("It reads the items before it and not the ones after it")
    func itReadsWhatIsUnderIt() {
        // The green square is drawn after the blur, so the blur cannot have
        // any of it: the pixels of the square are exactly green.
        let items = sides()
            + [.blur(square(x: 8, y: 8, width: 24, height: 24), radius: 8)]
            + [.fill(Rect(x: 14, y: 14, width: 12, height: 12), color: 0xFF00_FF00)]
        let pixels = picture(items)
        #expect(green(pixels, 20, 20) == 255)
        #expect(red(pixels, 20, 20) == 0)
    }
}

@Suite("A gradient")
struct GradientTests {
    /// Black to white, from the left edge of the square to its right edge.
    private var acrossTheSquare: Gradient {
        Gradient(from: 0xFF00_0000, to: 0xFFFF_FFFF,
                 startX: 12, startY: 0, endX: 28, endY: 0)
    }

    @Test("One end has the first colour and the other end has the second")
    func theEndsAreTheColours() {
        let pixels = picture([.gradient(square(), acrossTheSquare)])
        #expect(red(pixels, 13, 20) < 40)
        #expect(red(pixels, 27, 20) > 215)
    }

    @Test("The middle is between the two")
    func theMiddleIsBetween() {
        let pixels = picture([.gradient(square(), acrossTheSquare)])
        let middle = red(pixels, 20, 20)
        #expect(middle > 100 && middle < 160, "got \(middle)")
    }

    @Test("It rises from one end to the other")
    func itRises() {
        let pixels = picture([.gradient(square(), acrossTheSquare)])
        var last = -1
        for x in 13..<27 {
            let value = red(pixels, x, 20)
            #expect(value >= last, "it went back at \(x): \(value) after \(last)")
            last = value
        }
    }

    @Test("It stays inside the shape")
    func itStaysInside() {
        let pixels = picture([.gradient(square(), acrossTheSquare)])
        #expect(red(pixels, 2, 2) == 0)
    }
}
