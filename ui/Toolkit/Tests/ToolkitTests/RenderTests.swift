import Render
import Testing
@testable import Toolkit

// These tests check the three things that the renderer learned for the new
// shell: a clip that cuts drawing to a rectangle, a fill that carries alpha,
// and a line along a shape. Each one is tested on the display list and on the
// pixels, because a correct list that draws the wrong pixels is still wrong.

/// Draws a display list into a small canvas and gives the pixels back.
private func pixels(_ list: DisplayList, width: Int, height: Int,
                    background: UInt32 = 0xFF000000) -> [UInt32] {
    var buffer = [UInt32](repeating: background, count: width * height)
    buffer.withUnsafeMutableBufferPointer { memory in
        SoftwareRenderer.render(list, into: Canvas(pixels: memory.baseAddress!,
                                                   width: width, height: height, stride: width))
    }
    return buffer
}

private func pixel(_ buffer: [UInt32], _ x: Int, _ y: Int, width: Int) -> UInt32 {
    buffer[y * width + x]
}

@Suite("A clip rectangle")
struct ClipTests {
    @Test("A clipped view brackets its items with a push and a pop")
    func clipBracketsTheItems() {
        let view = Color(hex: 0xFF0000).clipped()
        let list = ViewRenderer.displayList(for: view, in: Rect(x: 0, y: 0, width: 10, height: 10))
        guard case .pushClip(let rect) = list.first else {
            Issue.record("expected a pushClip, got \(list)")
            return
        }
        #expect(rect == Rect(x: 0, y: 0, width: 10, height: 10))
        guard case .popClip = list.last else {
            Issue.record("expected a popClip, got \(list)")
            return
        }
    }

    @Test("The renderer draws nothing outside the clip")
    func theClipCutsAFill() {
        // A red fill of the whole canvas, cut to the left half.
        let list: DisplayList = [
            .pushClip(Rect(x: 0, y: 0, width: 2, height: 4)),
            .fill(Rect(x: 0, y: 0, width: 4, height: 4), color: 0xFFFF0000),
            .popClip,
        ]
        let buffer = pixels(list, width: 4, height: 4)
        #expect(pixel(buffer, 0, 0, width: 4) == 0xFFFF0000)
        #expect(pixel(buffer, 1, 3, width: 4) == 0xFFFF0000)
        // Outside the clip the background stays.
        #expect(pixel(buffer, 2, 0, width: 4) == 0xFF000000)
        #expect(pixel(buffer, 3, 3, width: 4) == 0xFF000000)
    }

    @Test("A clip inside a clip gives the part that both cover")
    func clipsNest() {
        let list: DisplayList = [
            .pushClip(Rect(x: 0, y: 0, width: 3, height: 4)),
            .pushClip(Rect(x: 2, y: 0, width: 2, height: 4)),
            .fill(Rect(x: 0, y: 0, width: 4, height: 4), color: 0xFFFF0000),
            .popClip,
            .popClip,
        ]
        let buffer = pixels(list, width: 4, height: 4)
        // Only column 2 is inside both clips.
        #expect(pixel(buffer, 1, 0, width: 4) == 0xFF000000)
        #expect(pixel(buffer, 2, 0, width: 4) == 0xFFFF0000)
        #expect(pixel(buffer, 3, 0, width: 4) == 0xFF000000)
    }

    @Test("A pop puts the clip that came before it back")
    func popRestoresTheClipBefore() {
        let list: DisplayList = [
            .pushClip(Rect(x: 0, y: 0, width: 2, height: 4)),
            .popClip,
            .fill(Rect(x: 0, y: 0, width: 4, height: 1), color: 0xFFFF0000),
        ]
        let buffer = pixels(list, width: 4, height: 4)
        // The fill comes after the pop, so the whole row is drawn.
        #expect(pixel(buffer, 3, 0, width: 4) == 0xFFFF0000)
    }

    @Test("The clip cuts a bitmap as well")
    func theClipCutsABitmap() {
        let bitmap = Bitmap(width: 4, height: 1, isOpaque: true,
                            pixels: [UInt32](repeating: 0xFF00FF00, count: 4))
        let list: DisplayList = [
            .pushClip(Rect(x: 1, y: 0, width: 2, height: 1)),
            .bitmap(bitmap, x: 0, y: 0),
            .popClip,
        ]
        let buffer = pixels(list, width: 4, height: 1)
        #expect(pixel(buffer, 0, 0, width: 4) == 0xFF000000)
        #expect(pixel(buffer, 1, 0, width: 4) == 0xFF00FF00)
        #expect(pixel(buffer, 2, 0, width: 4) == 0xFF00FF00)
        #expect(pixel(buffer, 3, 0, width: 4) == 0xFF000000)
    }

    @Test("A click outside the clip does not reach the view")
    func theClipCutsATapRegion() {
        // A button 40 tall, in a frame 10 tall, cut to it.
        let view = Button("press") {}
            .frame(width: 40, height: 10)
            .clipped()
        let pass = ViewRenderer.render(view, in: Rect(x: 0, y: 0, width: 40, height: 40))
        guard let region = pass.tapRegions.last else {
            Issue.record("expected a tap region")
            return
        }
        #expect(region.frame.height <= 10)
    }
}

@Suite("A fill with alpha")
struct AlphaFillTests {
    @Test("An opaque fill writes the colour")
    func anOpaqueFillWrites() {
        let buffer = pixels([.fill(Rect(x: 0, y: 0, width: 1, height: 1), color: 0xFFFF0000)],
                            width: 1, height: 1)
        #expect(buffer[0] == 0xFFFF0000)
    }

    @Test("A fill that is half there blends with what is under it")
    func aHalfFillBlends() {
        // Premultiplied red at alpha 128 over black: red ends near 128.
        let buffer = pixels([.fill(Rect(x: 0, y: 0, width: 1, height: 1), color: 0x80800000)],
                            width: 1, height: 1, background: 0xFF000000)
        let red = (buffer[0] >> 16) & 0xFF
        #expect(red >= 126 && red <= 130)
    }

    @Test("What is under a fill reaches the result")
    func whatIsUnderTheFillCounts() {
        // Black at two thirds over a colour: the colour keeps a third of
        // itself. Over black every blend looks the same whether or not the
        // colour under it is used at all, so this test uses a colour.
        let buffer = pixels([.fill(Rect(x: 0, y: 0, width: 1, height: 1), color: 0xA8000000)],
                            width: 1, height: 1, background: 0xFF12161A)
        #expect(buffer[0] & 0xFFFFFF == 0x060708)
    }

    @Test("A colour under a translucent bitmap reaches the result")
    func whatIsUnderABitmapCounts() {
        let bitmap = Bitmap(width: 1, height: 1, isOpaque: false, pixels: [0xA8000000])
        let buffer = pixels([.bitmap(bitmap, x: 0, y: 0)],
                            width: 1, height: 1, background: 0xFF12161A)
        #expect(buffer[0] & 0xFFFFFF == 0x060708)
    }

    @Test("A fill with no alpha draws nothing")
    func anEmptyFillDrawsNothing() {
        let buffer = pixels([.fill(Rect(x: 0, y: 0, width: 1, height: 1), color: 0x00FF0000)],
                            width: 1, height: 1, background: 0xFF123456)
        #expect(buffer[0] == 0xFF123456)
    }
}

@Suite("A line along a shape")
struct StrokeTests {
    @Test("A reversed path ends where the first one starts")
    func reversedPathTurnsAround() {
        var path = Path()
        path.addRectangle(x: 0, y: 0, width: 10, height: 10)
        let back = path.reversed()
        guard case .move(let x, let y) = back.elements.first else {
            Issue.record("expected a move, got \(back.elements)")
            return
        }
        // The first path starts at (0, 0) and its last corner is (0, 10).
        #expect((x, y) == (0, 10))
        #expect(back.elements.count == path.elements.count)
    }

    @Test("A stroke leaves the middle of the shape empty")
    func strokeIsHollow() {
        let view = Rectangle().stroke(Color(hex: 0xFF0000), lineWidth: 2)
        let list = ViewRenderer.displayList(for: view, in: Rect(x: 0, y: 0, width: 10, height: 10))
        let buffer = pixels(list, width: 10, height: 10)
        // The edge is drawn.
        #expect(pixel(buffer, 0, 5, width: 10) == 0xFFFF0000)
        #expect(pixel(buffer, 9, 5, width: 10) == 0xFFFF0000)
        #expect(pixel(buffer, 5, 0, width: 10) == 0xFFFF0000)
        // The middle is not.
        #expect(pixel(buffer, 5, 5, width: 10) == 0xFF000000)
    }

    @Test("A thicker line covers more of the shape")
    func aThickerLineCoversMore() {
        func drawn(_ width: Double) -> Int {
            let view = Rectangle().stroke(Color(hex: 0xFF0000), lineWidth: width)
            let list = ViewRenderer.displayList(for: view, in: Rect(x: 0, y: 0, width: 20, height: 20))
            return pixels(list, width: 20, height: 20).count { $0 != 0xFF000000 }
        }
        #expect(drawn(4) > drawn(1))
    }

    @Test("A line of no width draws nothing")
    func noWidthDrawsNothing() {
        let view = Rectangle().stroke(Color(hex: 0xFF0000), lineWidth: 0)
        #expect(ViewRenderer.displayList(for: view, in: Rect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
    }
}
