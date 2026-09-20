import Render
import Testing
@testable import Toolkit

// A shape gives a path, and the renderer fills it. The last test draws real
// pixels, because a path that is correct on paper can still be empty on the
// screen.

private func paths(_ view: some View, width: Int, height: Int) -> [(Path, UInt32)] {
    ViewRenderer.displayList(for: view, in: Rect(x: 0, y: 0, width: width, height: height))
        .compactMap { item in
            if case .path(let path, let color) = item { (path, color) } else { nil }
        }
}

/// The smallest rectangle around the points of a path.
private func bounds(_ path: Path) -> (x: Double, y: Double, width: Double, height: Double) {
    var points: [(Double, Double)] = []
    for element in path.elements {
        switch element {
        case .move(let x, let y), .line(let x, let y): points.append((x, y))
        case .quadratic(_, _, let x, let y): points.append((x, y))
        case .cubic(_, _, _, _, let x, let y): points.append((x, y))
        case .close: break
        }
    }
    let xs = points.map(\.0), ys = points.map(\.1)
    return (xs.min() ?? 0, ys.min() ?? 0,
            (xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
}

/// Draws a display list into a small image and gives the pixels.
private func draw(_ list: DisplayList, width: Int, height: Int) -> [UInt32] {
    let pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
    defer { pixels.deallocate() }
    pixels.update(repeating: 0xFF000000, count: width * height)
    SoftwareRenderer.render(list, into: Canvas(pixels: pixels, width: width, height: height,
                                               stride: width))
    return Array(UnsafeBufferPointer(start: pixels, count: width * height))
}

@Suite("Shapes")
struct ShapeTests {
    @Test("A circle uses the shorter side and sits in the middle")
    func circleFitsTheShorterSide() {
        let drawn = paths(Circle(), width: 100, height: 50)
        #expect(drawn.count == 1)
        let box = bounds(drawn[0].0)
        #expect(box.width == 50 && box.height == 50)
        #expect(box.x == 25 && box.y == 0)
    }

    @Test("A shape uses the foreground colour, and fill gives it another one")
    func shapeColors() {
        #expect(paths(Circle().foregroundColor(Color(hex: 0x00FF00)), width: 20, height: 20)[0].1
                == 0xFF00FF00)
        #expect(paths(Circle().fill(Color(hex: 0xFF0000)), width: 20, height: 20)[0].1
                == 0xFFFF0000)
    }

    @Test("A rounded rectangle keeps its corners inside the frame")
    func roundedRectangleBounds() {
        let box = bounds(paths(RoundedRectangle(cornerRadius: 8), width: 40, height: 30)[0].0)
        #expect(box.x == 0 && box.y == 0 && box.width == 40 && box.height == 30)
    }

    @Test("A radius larger than the shape becomes a capsule")
    func radiusIsLimited() {
        let large = paths(RoundedRectangle(cornerRadius: 999), width: 40, height: 20)[0].0
        let capsule = paths(Capsule(), width: 40, height: 20)[0].0
        #expect(large == capsule)
    }

    @Test("A rectangle draws as a plain fill, not as a path")
    func rectangleIsAFill() {
        let list = ViewRenderer.displayList(for: Rectangle(), in: Rect(x: 0, y: 0, width: 10, height: 10))
        #expect(list.count == 1)
        if case .fill = list[0] {} else { Issue.record("expected a fill, got \(list[0])") }
    }

    @Test("A filled circle covers the middle and leaves the corners empty")
    func circlePixels() {
        let list = ViewRenderer.displayList(for: Circle().fill(Color(hex: 0xFF0000)),
                                            in: Rect(x: 0, y: 0, width: 20, height: 20))
        let pixels = draw(list, width: 20, height: 20)
        #expect(pixels[10 * 20 + 10] == 0xFFFF0000, "the middle is red")
        #expect(pixels[0] == 0xFF000000, "the corner is not painted")
        #expect(pixels[19 * 20 + 19] == 0xFF000000, "the other corner is not painted either")
        #expect(pixels[10 * 20 + 19] != 0xFF000000, "the middle row reaches the right edge")
    }

    @Test("The edge of a circle is smooth: it has partly covered pixels")
    func circleEdgeIsSmooth() {
        let list = ViewRenderer.displayList(for: Circle().fill(Color(hex: 0xFF0000)),
                                            in: Rect(x: 0, y: 0, width: 20, height: 20))
        let pixels = draw(list, width: 20, height: 20)
        let partly = pixels.filter { pixel in
            let red = (pixel >> 16) & 0xFF
            return red > 0 && red < 0xFF
        }
        #expect(partly.count > 8, "expected soft edge pixels, got \(partly.count)")
    }
}

@Suite("Aspect ratio")
struct AspectRatioTests {
    private func size(_ view: some View, width: Double, height: Double) -> Size {
        ViewRenderer.size(of: view, fitting: Proposal(width: width, height: height))
    }

    @Test("A wide ratio that must fit uses the full width")
    func fitUsesTheFullWidth() {
        #expect(size(Color.red.aspectRatio(2, contentMode: .fit), width: 100, height: 100)
                == Size(width: 100, height: 50))
    }

    @Test("A tall space that must fit uses the full height")
    func fitUsesTheFullHeight() {
        #expect(size(Color.red.aspectRatio(2, contentMode: .fit), width: 100, height: 20)
                == Size(width: 40, height: 20))
    }

    @Test("A ratio that must fill covers the whole space")
    func fillCoversTheSpace() {
        #expect(size(Color.red.aspectRatio(2, contentMode: .fill), width: 100, height: 100)
                == Size(width: 200, height: 100))
    }

    @Test("A square ratio in a wide space is as tall as the space")
    func squareInAWideSpace() {
        let items = ViewRenderer.displayList(for: Color.red.aspectRatio(1, contentMode: .fit),
                                             in: Rect(x: 0, y: 0, width: 100, height: 40))
        guard case .fill(let rect, _) = items[0] else {
            Issue.record("expected a fill")
            return
        }
        #expect(rect == Rect(x: 30, y: 0, width: 40, height: 40))
    }

    @Test("A view with a fixed size keeps it inside an aspect ratio")
    func fixedSizeInsideAnAspectRatio() {
        // The aspect ratio offers a square space. The frame is 44 x 44 and
        // must stay 44 x 44, however large the space is.
        let view = Color.red.frame(width: 44, height: 44).aspectRatio(1, contentMode: .fit)
        #expect(size(view, width: 1280, height: 400) == Size(width: 44, height: 44))
        let items = ViewRenderer.displayList(for: view, in: Rect(x: 0, y: 0, width: 100, height: 100))
        guard case .fill(let rect, _) = items.first else {
            Issue.record("expected a fill")
            return
        }
        #expect(rect == Rect(x: 28, y: 28, width: 44, height: 44))
    }

    @Test("A frame keeps its size when the space that it gets is larger")
    func frameKeepsItsSizeInALargerSpace() {
        let node = FrameNode(child: FillNode(color: .red), width: 20, height: 10)
        var pass = RenderPass()
        node.render(in: Frame(x: 0, y: 0, width: 100, height: 100), into: &pass)
        guard case .fill(let rect, _) = pass.list.first else {
            Issue.record("expected a fill")
            return
        }
        #expect(rect == Rect(x: 40, y: 45, width: 20, height: 10))
    }

    @Test("scaledToFit keeps the proportions that the content asks for")
    func scaledToFitUsesTheContentRatio() {
        // Text is wider than it is tall, so it keeps that shape.
        let text = Text("Hello").font(Font(size: 16))
        let ideal = ViewRenderer.size(of: text, fitting: .unspecified)
        let scaled = size(text.scaledToFit(), width: ideal.width * 2, height: ideal.height * 2)
        #expect(abs(scaled.width / scaled.height - ideal.width / ideal.height) < 0.001)
    }
}
