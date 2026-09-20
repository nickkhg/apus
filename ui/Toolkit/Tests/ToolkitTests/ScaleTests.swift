import Render
import Testing
@testable import Toolkit

// A screen can have more than one pixel to the point. The layout always
// works in points, so a view has the same size on every screen, and only the
// drawing items are in pixels. These tests hold that line: the same view at
// scale 2 must give the same layout and twice the pixels.

private func fills(_ view: some View, width: Int, height: Int, scale: Double) -> [(Rect, UInt32)] {
    ViewRenderer.displayList(for: view, in: Rect(x: 0, y: 0, width: width, height: height),
                             scale: scale)
        .compactMap { item in
            if case .fill(let rect, let color) = item { (rect, color) } else { nil }
        }
}

@Suite("A screen with two pixels to the point")
struct ScaleTests {
    @Test("A fill covers twice as many pixels")
    func aFillIsTwiceTheSize() {
        let view = Color(hex: 0xFF0000).frame(width: 10, height: 5)
        let one = fills(view, width: 100, height: 100, scale: 1)
        let two = fills(view, width: 100, height: 100, scale: 2)
        #expect(one[0].0.width == 10 && one[0].0.height == 5)
        #expect(two[0].0.width == 20 && two[0].0.height == 10)
    }

    @Test("A view keeps its place in points, so every pixel doubles")
    func aViewKeepsItsPlace() {
        // The layout must not change with the scale. Whatever the stack
        // decides in points, the pixels are exactly twice as far out.
        let view = VStack(spacing: 0) {
            Color(hex: 0xFF0000).frame(width: 10, height: 10)
            Spacer()
        }
        let one = fills(view, width: 40, height: 40, scale: 1)
        let two = fills(view, width: 40, height: 40, scale: 2)
        #expect(two[0].0.x == one[0].0.x * 2)
        #expect(two[0].0.y == one[0].0.y * 2)
        #expect(two[0].0.width == one[0].0.width * 2)
        #expect(two[0].0.height == one[0].0.height * 2)
    }

    @Test("A shape is a path in pixels")
    func aShapeScales() {
        let view = RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 20, height: 20)
        let list = ViewRenderer.displayList(for: view, in: Rect(x: 0, y: 0, width: 40, height: 40),
                                            scale: 2)
        guard case .path(let path, _) = list.first(where: { if case .path = $0 { true } else { false } }) else {
            Issue.record("expected a path, got \(list)")
            return
        }
        // The shape is 20 points across, so its outline reaches 40 pixels.
        var widest = 0.0
        for element in path.elements {
            if case .line(let x, _) = element { widest = max(widest, x) }
            if case .move(let x, _) = element { widest = max(widest, x) }
        }
        #expect(widest > 30)
    }

    @Test("A clip is in pixels too")
    func aClipScales() {
        let view = Color(hex: 0xFF0000).frame(width: 10, height: 10).clipped()
        let list = ViewRenderer.displayList(for: view, in: Rect(x: 0, y: 0, width: 40, height: 40),
                                            scale: 2)
        guard case .pushClip(let rect) = list.first else {
            Issue.record("expected a pushClip, got \(list)")
            return
        }
        #expect(rect.width == 20 && rect.height == 20)
    }

    @Test("Text keeps its size in points and its glyphs in pixels")
    func textScales() {
        let text = Text("mydistro").font(.body)
        let one = ViewRenderer.size(of: text, fitting: .unspecified, scale: 1)
        let two = ViewRenderer.size(of: text, fitting: .unspecified, scale: 2)
        // The layout is the same, within the rounding of a point.
        #expect(abs(one.width - two.width) <= 1)
        #expect(abs(one.height - two.height) <= 1)

        // The bitmap that is drawn is twice as wide, because the glyphs are
        // made at twice the size.
        func bitmapWidth(_ scale: Double) -> Int {
            let list = ViewRenderer.displayList(for: text, in: Rect(x: 0, y: 0, width: 400, height: 100),
                                                scale: scale)
            for item in list {
                if case .bitmap(let bitmap, _, _) = item { return bitmap.width }
            }
            return 0
        }
        let small = bitmapWidth(1)
        let large = bitmapWidth(2)
        #expect(small > 0)
        #expect(large >= small * 2 - 4 && large <= small * 2 + 4)
    }

    @Test("A place that answers the pointer stays in points")
    func regionsStayInPoints() {
        // The compositor gives the host a pointer in points, so a region
        // must be the same whatever the scale of the screen is.
        let view = Button("press") {}
        let space = Rect(x: 0, y: 0, width: 200, height: 80)
        guard let one = ViewRenderer.render(view, in: space, scale: 1).tapRegions.last,
              let two = ViewRenderer.render(view, in: space, scale: 2).tapRegions.last else {
            Issue.record("expected a tap region")
            return
        }
        #expect(one.frame == two.frame)
        #expect(two.frame.width > 0)
    }
}
