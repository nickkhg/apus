import Render
import Testing
@testable import Toolkit

// The tests check the display list: where each view ends up, and in which
// order the items are drawn. A display list is the compositor's input, so
// these tests test what the screen shows, without a screen.

/// The fill rectangles of a view laid out in `width` × `height`.
private func fills(_ view: some View, width: Int, height: Int) -> [(Rect, UInt32)] {
    ViewRenderer.displayList(for: view, in: Rect(x: 0, y: 0, width: width, height: height))
        .compactMap { item in
            if case .fill(let rect, let color) = item { (rect, color) } else { nil }
        }
}

private let red = Color(hex: 0xFF0000)
private let green = Color(hex: 0x00FF00)
private let blue = Color(hex: 0x0000FF)

@Suite("Colour")
struct ColorTests {
    @Test("A colour fills the space that it gets")
    func colorFillsItsSpace() {
        let items = fills(red, width: 100, height: 50)
        #expect(items.count == 1)
        #expect(items[0].0 == Rect(x: 0, y: 0, width: 100, height: 50))
        #expect(items[0].1 == 0xFF0000)
    }

    @Test("A translucent colour becomes a bitmap, because fills do not blend")
    func translucentColorBecomesBitmap() {
        let list = ViewRenderer.displayList(for: red.opacity(0.5),
                                            in: Rect(x: 0, y: 0, width: 4, height: 2))
        guard case .bitmap(let bitmap, let x, let y) = list.first else {
            Issue.record("expected a bitmap, got \(list)")
            return
        }
        #expect((x, y) == (0, 0))
        #expect(bitmap.width == 4 && bitmap.height == 2)
        #expect(bitmap.isOpaque == false)
        // Premultiplied: alpha 128, red 128.
        #expect(bitmap.pixels.allSatisfy { $0 == 0x80800000 })
    }

    @Test("A clear colour draws nothing")
    func clearColorDrawsNothing() {
        #expect(ViewRenderer.displayList(for: Color.clear,
                                         in: Rect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
    }
}

@Suite("Stacks")
struct StackTests {
    @Test("A column gives each fixed row its height, from the top")
    func columnOfFixedRows() {
        let view = VStack {
            red.frame(height: 20)
            green.frame(height: 30)
        }
        let items = fills(view, width: 100, height: 50)
        #expect(items.map(\.0) == [Rect(x: 0, y: 0, width: 100, height: 20),
                                   Rect(x: 0, y: 20, width: 100, height: 30)])
    }

    @Test("Spacing goes between the rows, not outside them")
    func spacingBetweenRows() {
        let view = VStack(spacing: 10) {
            red.frame(height: 20)
            green.frame(height: 20)
        }
        let items = fills(view, width: 10, height: 50)
        #expect(items.map(\.0.y) == [0, 30])
    }

    @Test("A spacer takes the space that the other views leave")
    func spacerTakesTheRest() {
        let view = HStack {
            red.frame(width: 20)
            Spacer()
            green.frame(width: 30)
        }
        let items = fills(view, width: 100, height: 10)
        #expect(items.map(\.0.x) == [0, 70])
        #expect(items.map(\.0.width) == [20, 30])
    }

    @Test("Two spacers share the free space")
    func twoSpacersShare() {
        let view = HStack {
            Spacer()
            red.frame(width: 20)
            Spacer()
        }
        let items = fills(view, width: 100, height: 10)
        #expect(items[0].0 == Rect(x: 40, y: 0, width: 20, height: 10))
    }

    @Test("A row centres its children across the axis")
    func rowCentresAcross() {
        let view = HStack {
            red.frame(width: 10, height: 10)
        }
        let items = fills(view, width: 10, height: 50)
        #expect(items[0].0 == Rect(x: 0, y: 20, width: 10, height: 10))
    }

    @Test("A row with top alignment puts a short child at the top")
    func rowAlignsTop() {
        let view = HStack(alignment: .top) {
            red.frame(width: 10, height: 10)
            green.frame(width: 10, height: 30)
        }
        // The row is 20 x 30, in the middle of 100 x 50.
        #expect(fills(view, width: 100, height: 50).map(\.0)
                == [Rect(x: 40, y: 10, width: 10, height: 10),
                    Rect(x: 50, y: 10, width: 10, height: 30)])
    }

    @Test("A column with trailing alignment puts a narrow child on the right")
    func columnAlignsTrailing() {
        let view = VStack(alignment: .trailing) {
            red.frame(width: 10, height: 10)
            green.frame(width: 40, height: 10)
        }
        // The column is 40 x 20, in the middle of 100 x 20.
        #expect(fills(view, width: 100, height: 20).map(\.0.x) == [60, 30])
    }

    @Test("A layer stack draws the first view at the back")
    func layerStackOrder() {
        let view = ZStack {
            red
            green.frame(width: 10, height: 10)
        }
        let items = fills(view, width: 50, height: 50)
        #expect(items.map(\.1) == [0xFF0000, 0x00FF00])
        #expect(items[1].0 == Rect(x: 20, y: 20, width: 10, height: 10))
    }

    @Test("A layer stack puts a small view where the alignment says")
    func layerStackAlignment() {
        let view = ZStack(alignment: .bottomTrailing) {
            red.frame(width: 50, height: 50)
            green.frame(width: 10, height: 10)
        }
        #expect(fills(view, width: 50, height: 50).map(\.0)
                == [Rect(x: 0, y: 0, width: 50, height: 50),
                    Rect(x: 40, y: 40, width: 10, height: 10)])
    }
}

@Suite("Modifiers")
struct ModifierTests {
    @Test("Padding makes the view smaller by the insets")
    func paddingInsetsTheChild() {
        let items = fills(red.padding(10), width: 100, height: 100)
        #expect(items[0].0 == Rect(x: 10, y: 10, width: 80, height: 80))
    }

    @Test("Padding on one side only moves that side")
    func paddingOneEdge() {
        let items = fills(red.padding(.leading, 20), width: 100, height: 100)
        #expect(items[0].0 == Rect(x: 20, y: 0, width: 80, height: 100))
    }

    @Test("A fixed frame centres the view in the space that it gets")
    func fixedFrameCentres() {
        let items = fills(red.frame(width: 20, height: 20), width: 100, height: 100)
        #expect(items[0].0 == Rect(x: 40, y: 40, width: 20, height: 20))
    }

    @Test("A frame with an alignment puts a smaller child in that corner")
    func frameAlignment() {
        let view = red.frame(width: 10, height: 10)
            .frame(width: 50, height: 50, alignment: .topLeading)
        // The 50 x 50 frame goes in the middle of 100 x 100, at 25,25.
        #expect(fills(view, width: 100, height: 100)[0].0 == Rect(x: 25, y: 25, width: 10, height: 10))
    }

    @Test("maxWidth .infinity makes a view take the width that it gets")
    func maxWidthInfinity() {
        let view = HStack {
            red.frame(maxWidth: .infinity)
            green.frame(width: 30)
        }
        let items = fills(view, width: 100, height: 10)
        #expect(items.map(\.0.width) == [70, 30])
    }

    @Test("A background is drawn first, with the same frame")
    func backgroundIsDrawnFirst() {
        let view = red.frame(width: 20, height: 20).background(blue)
        let items = fills(view, width: 20, height: 20)
        #expect(items.map(\.1) == [0x0000FF, 0xFF0000])
        #expect(items[0].0 == items[1].0)
    }

    @Test("An offset moves the view and keeps its size")
    func offsetMovesTheView() {
        let items = fills(red.frame(width: 10, height: 10).offset(x: 5, y: -5),
                          width: 100, height: 100)
        #expect(items[0].0 == Rect(x: 50, y: 40, width: 10, height: 10))
    }

    @Test("A rectangle uses the foreground colour")
    func rectangleUsesForegroundColor() {
        let items = fills(Rectangle().foregroundColor(green), width: 10, height: 10)
        #expect(items[0].1 == 0x00FF00)
    }
}

@Suite("Builder")
struct BuilderTests {
    struct Row: View {
        let show: Bool
        var body: some View {
            HStack {
                if show {
                    red.frame(width: 10)
                }
                green.frame(width: 10)
            }
        }
    }

    @Test("An if in a builder adds the view only when the value is true")
    func conditionalContent() {
        #expect(fills(Row(show: true), width: 100, height: 10).count == 2)
        #expect(fills(Row(show: false), width: 100, height: 10).count == 1)
    }

    @Test("ForEach makes one view for each element")
    func forEachMakesOneViewPerElement() {
        let view = VStack {
            ForEach(0..<4) { _ in red.frame(height: 10) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        let items = fills(view, width: 10, height: 100)
        #expect(items.map(\.0.y) == [0, 10, 20, 30])
    }

    @Test("An empty body draws nothing")
    func emptyBodyDrawsNothing() {
        #expect(fills(EmptyView(), width: 10, height: 10).isEmpty)
    }

    @Test("A body of any type draws its content")
    func anyViewDrawsItsContent() {
        #expect(fills(AnyView(red), width: 10, height: 10).count == 1)
    }
}

@Suite("Size")
struct SizeTests {
    @Test("A column asks for the sum of its rows and the spacing")
    func columnIdealSize() {
        let view = VStack(spacing: 4) {
            red.frame(width: 30, height: 10)
            green.frame(width: 50, height: 20)
        }
        let size = ViewRenderer.size(of: view, fitting: .unspecified)
        #expect(size == Size(width: 50, height: 34))
    }

    @Test("Padding adds to the size that the view asks for")
    func paddingAddsToTheSize() {
        let size = ViewRenderer.size(of: red.frame(width: 10, height: 10).padding(5),
                                     fitting: .unspecified)
        #expect(size == Size(width: 20, height: 20))
    }

    @Test("A view with no size of its own asks for 10 × 10")
    func shapeIdealSize() {
        #expect(ViewRenderer.size(of: red, fitting: .unspecified) == Size(width: 10, height: 10))
    }
}
