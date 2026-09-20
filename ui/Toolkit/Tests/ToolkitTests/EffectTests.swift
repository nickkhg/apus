import Render
import Testing
@testable import Toolkit

// The three views that ask for depth: a shadow behind a view, a blur under
// one, and a gradient in one. What each of them must put in the display
// list, and what each must leave out.

private func list(_ view: some View, width: Int = 100, height: Int = 60,
                  scale: Double = 1) -> DisplayList {
    ViewRenderer.displayList(for: view, in: Rect(x: 0, y: 0, width: width, height: height),
                             scale: scale)
}

private func shadows(_ list: DisplayList) -> [Shadow] {
    list.compactMap { if case .shadow(_, let shadow) = $0 { shadow } else { nil } }
}

private func blurs(_ list: DisplayList) -> [Double] {
    list.compactMap { if case .blur(_, let radius) = $0 { radius } else { nil } }
}

private func gradients(_ list: DisplayList) -> [Gradient] {
    list.compactMap { if case .gradient(_, let gradient) = $0 { gradient } else { nil } }
}

/// The top left and the bottom right of everything in a path.
private func corners(_ path: Path) -> (x: Double, y: Double, right: Double, bottom: Double) {
    var minimum = (x: Double.infinity, y: Double.infinity)
    var maximum = (x: -Double.infinity, y: -Double.infinity)
    for element in path.elements {
        let point: (x: Double, y: Double)? = switch element {
        case .move(let x, let y): (x, y)
        case .line(let x, let y): (x, y)
        case .quadratic(_, _, let x, let y): (x, y)
        case .cubic(_, _, _, _, let x, let y): (x, y)
        case .close: nil
        }
        guard let point else { continue }
        minimum = (min(minimum.x, point.x), min(minimum.y, point.y))
        maximum = (max(maximum.x, point.x), max(maximum.y, point.y))
    }
    return (minimum.x, minimum.y, maximum.x, maximum.y)
}

@Suite("A shadow behind a view")
struct ShadowViewTests {
    @Test("It goes in the list before the view that casts it")
    func itIsBehind() {
        let view = Color.white.frame(width: 20, height: 10)
            .shadow(radius: 8, y: 4)
        let items = list(view)
        guard case .shadow = items.first else {
            Issue.record("the shadow is not the first item: \(items)")
            return
        }
        #expect(shadows(items).count == 1)
    }

    @Test("A style of none draws nothing")
    func noneDrawsNothing() {
        let view = Color.white.frame(width: 20, height: 10).shadow(.none)
        #expect(shadows(list(view)).isEmpty)
    }

    @Test("It takes the frame of the view, and the corner that it was given")
    func itTakesTheFrame() {
        let view = Color.white.frame(width: 20, height: 10)
            .shadow(radius: 4, cornerRadius: 3)
        guard case .shadow(let path, _) = list(view).first else {
            Issue.record("no shadow")
            return
        }
        let box = corners(path)
        #expect(box.right - box.x == 20)
        #expect(box.bottom - box.y == 10)
    }

    @Test("The radius and the offset are in pixels")
    func itScales() {
        let view = Color.white.frame(width: 20, height: 10).shadow(radius: 6, y: 3)
        let one = shadows(list(view, scale: 1))[0]
        let two = shadows(list(view, scale: 2))[0]
        #expect(one.radius == 6 && one.dy == 3)
        #expect(two.radius == 12 && two.dy == 6)
    }
}

@Suite("A blur under a view")
struct BlurViewTests {
    @Test("It asks for a blur of the size that it was given, in pixels")
    func itScales() {
        let view = Blur(radius: 10).frame(width: 30, height: 20)
        #expect(blurs(list(view, scale: 1)) == [10])
        #expect(blurs(list(view, scale: 2)) == [20])
    }

    @Test("A blur of no radius asks for nothing")
    func noRadius() {
        #expect(blurs(list(Blur(radius: 0).frame(width: 30, height: 20))).isEmpty)
    }

    @Test("It goes under what it is the background of")
    func itIsUnderTheContent() {
        let view = Color.white.frame(width: 30, height: 20)
            .background(Blur(radius: 5))
        let items = list(view)
        guard case .blur = items.first else {
            Issue.record("the blur is not first: \(items)")
            return
        }
    }
}

@Suite("A gradient in a view")
struct GradientViewTests {
    @Test("It runs from one edge of the view to the other")
    func itRunsAcross() {
        let view = LinearGradient(from: .black, to: .white, direction: .down)
            .frame(width: 30, height: 20)
        let gradient = gradients(list(view))[0]
        // The view is 20 points tall, wherever the layout put it.
        #expect(gradient.endY - gradient.startY == 20)
        #expect(gradient.startX == gradient.endX)
    }

    @Test("Two ends of one colour are a plain fill, which costs less")
    func oneColourIsAFill() {
        let view = LinearGradient(from: .white, to: .white).frame(width: 30, height: 20)
        let items = list(view)
        #expect(gradients(items).isEmpty)
        #expect(items.contains { if case .path = $0 { true } else { false } })
    }

    @Test("A shape can hold one")
    func aShapeHoldsOne() {
        let view = RoundedRectangle(cornerRadius: 6)
            .fill(LinearGradient(from: .black, to: .white, direction: .right))
            .frame(width: 30, height: 20)
        #expect(gradients(list(view)).count == 1)
    }

    @Test("Opacity takes both ends with it")
    func opacityTakesBothEnds() {
        let gradient = LinearGradient(from: .white, to: .black).opacity(0.5)
        #expect(gradient.from.alpha == 0.5)
        #expect(gradient.to.alpha == 0.5)
    }
}
