import Render
import Testing
@testable import Toolkit

// What the graph does to a view tree: a body runs again only when something
// it depends on changed.
//
// Every test here counts the bodies that ran. A test that only checked the
// picture would pass with a toolkit that works the whole tree out every
// frame, which is what this one did before the graph.

/// How many times each view asked for its body.
private final class Count: @unchecked Sendable {
    var leaf = 0
    var parent = 0
}

/// A view that says when two of it are the same. The counter is not part of
/// that: it is the instrument, not the value.
private struct Leaf: View, Equatable {
    let label: String
    let count: Count

    static func == (a: Leaf, b: Leaf) -> Bool { a.label == b.label }

    var body: some View {
        count.leaf += 1
        return Color.white.frame(width: 10, height: 10)
    }
}

/// A view that never says it is the same, so its body always runs.
private struct Parent: View {
    let label: String
    let count: Count

    var body: some View {
        count.parent += 1
        return VStack(spacing: 0) {
            Leaf(label: label, count: count)
            Color.red.frame(width: 4, height: 4)
        }
    }
}

private let box = Rect(x: 0, y: 0, width: 100, height: 100)

@Suite("A body runs only when it must")
struct GraphViewTests {
    @Test("A view that is the same value keeps the nodes that it made")
    func anUnchangedViewIsNotAskedAgain() {
        let count = Count()
        let state = ViewState()
        _ = ViewRenderer.render(Parent(label: "a", count: count), in: box, state: state)
        #expect(count.leaf == 1)

        _ = ViewRenderer.render(Parent(label: "a", count: count), in: box, state: state)
        _ = ViewRenderer.render(Parent(label: "a", count: count), in: box, state: state)
        // The parent says nothing about itself, so it runs every time. The
        // leaf says it is the same, so it ran one time.
        #expect(count.parent == 3)
        #expect(count.leaf == 1)
    }

    @Test("A view whose value changed is asked again")
    func aChangedViewRunsAgain() {
        let count = Count()
        let state = ViewState()
        _ = ViewRenderer.render(Parent(label: "a", count: count), in: box, state: state)
        _ = ViewRenderer.render(Parent(label: "b", count: count), in: box, state: state)
        #expect(count.leaf == 2)
    }

    @Test("The picture is the same whether the body ran or not")
    func theSamePictureComesBack() {
        let count = Count()
        let state = ViewState()
        let first = ViewRenderer.render(Parent(label: "a", count: count), in: box, state: state).list
        let second = ViewRenderer.render(Parent(label: "a", count: count), in: box, state: state).list
        #expect(first.count == second.count)
        for (one, two) in zip(first, second) {
            guard case .fill(let a, let colorA) = one, case .fill(let b, let colorB) = two else {
                continue
            }
            #expect(a == b && colorA == colorB)
        }
    }

    @Test("A change of the environment asks every view under it again")
    func theEnvironmentReachesTheTree() {
        let count = Count()
        let state = ViewState()
        struct Coloured: View {
            let label: String
            let count: Count
            let color: Color
            var body: some View {
                Leaf(label: label, count: count).foregroundColor(color)
            }
        }
        _ = ViewRenderer.render(Coloured(label: "a", count: count, color: .white),
                                in: box, state: state)
        #expect(count.leaf == 1)
        _ = ViewRenderer.render(Coloured(label: "a", count: count, color: .red),
                                in: box, state: state)
        #expect(count.leaf == 2, "the leaf drew in the old colour")
    }
}

@Suite("A change of state reaches the views that read it")
struct GraphStateTests {
    /// A leaf with a value of its own. The handler is how a test changes it.
    private struct Switch: View, Equatable {
        let label: String
        let count: Count
        let hold: Hold
        @State private var on = false

        static func == (a: Switch, b: Switch) -> Bool { a.label == b.label }

        var body: some View {
            count.leaf += 1
            hold.toggle = { on.toggle() }
            return Color.white.frame(width: on ? 20 : 10, height: 10)
        }
    }

    /// Where the test keeps the handler of the view.
    private final class Hold: @unchecked Sendable {
        var toggle: () -> Void = {}
    }

    private struct Pair: View {
        let count: Count
        let first: Hold
        let second: Hold

        var body: some View {
            count.parent += 1
            return VStack(spacing: 0) {
                Switch(label: "first", count: count, hold: first)
                Switch(label: "second", count: count, hold: second)
            }
        }
    }

    @Test("Only the view whose value changed is asked for its body again")
    func oneChangeReachesOneView() {
        let count = Count()
        let (first, second) = (Hold(), Hold())
        let state = ViewState()
        let view = Pair(count: count, first: first, second: second)
        _ = ViewRenderer.render(view, in: box, state: state)
        #expect(count.leaf == 2)

        first.toggle()
        _ = ViewRenderer.render(view, in: box, state: state)
        // The first switch ran again. The second one did not: nothing that
        // it reads changed.
        #expect(count.leaf == 3)
    }

    @Test("The new value is in the picture")
    func theChangeIsDrawn() {
        let count = Count()
        let (first, second) = (Hold(), Hold())
        let state = ViewState()
        let view = Pair(count: count, first: first, second: second)

        func widths(_ pass: RenderPass) -> [Int] {
            pass.list.compactMap { if case .fill(let rect, _) = $0 { rect.width } else { nil } }
        }
        #expect(widths(ViewRenderer.render(view, in: box, state: state)) == [10, 10])
        first.toggle()
        #expect(widths(ViewRenderer.render(view, in: box, state: state)) == [20, 10])
    }

    @Test("The state of a view that kept its nodes is still there")
    func stateSurvivesAKeptSubtree() {
        let count = Count()
        let (first, second) = (Hold(), Hold())
        let state = ViewState()
        let view = Pair(count: count, first: first, second: second)
        _ = ViewRenderer.render(view, in: box, state: state)
        let stored = state.count
        // Three passes in which the two leaves keep their nodes.
        _ = ViewRenderer.render(view, in: box, state: state)
        _ = ViewRenderer.render(view, in: box, state: state)
        _ = ViewRenderer.render(view, in: box, state: state)
        #expect(state.count == stored, "the state under a kept view was thrown away")
        // And the state still works.
        second.toggle()
        let pass = ViewRenderer.render(view, in: box, state: state)
        let widths = pass.list.compactMap { item -> Int? in
            if case .fill(let rect, _) = item { rect.width } else { nil }
        }
        #expect(widths == [10, 20])
    }
}

@Suite("What the graph holds")
struct GraphSizeTests {
    /// A view with a value of its own, so that the store holds something.
    private struct Counter: View, Equatable {
        let label: String
        @State private var count = 0

        static func == (a: Counter, b: Counter) -> Bool { a.label == b.label }

        var body: some View {
            Color.white.frame(width: Double(10 + count), height: 4)
        }
    }

    private struct Maybe: View {
        let show: Bool

        var body: some View {
            VStack(spacing: 0) {
                if show { Counter(label: "one") }
                Color.red.frame(width: 5, height: 5)
            }
        }
    }

    @Test("A view that goes away takes its attributes with it")
    func theGraphDoesNotGrow() {
        let state = ViewState()
        let box = Rect(x: 0, y: 0, width: 100, height: 100)
        _ = ViewRenderer.render(Maybe(show: true), in: box, state: state)
        let withCounter = state.graph.count
        _ = ViewRenderer.render(Maybe(show: false), in: box, state: state)
        let without = state.graph.count
        #expect(without < withCounter, "the graph kept the view that went away")

        // And it does not grow when the same tree is drawn again.
        _ = ViewRenderer.render(Maybe(show: false), in: box, state: state)
        _ = ViewRenderer.render(Maybe(show: false), in: box, state: state)
        #expect(state.graph.count == without)
    }

    @Test("A tree that opens and closes leaves nothing behind")
    func openingAndClosingLeavesNothing() {
        let state = ViewState()
        let box = Rect(x: 0, y: 0, width: 100, height: 100)
        _ = ViewRenderer.render(Maybe(show: false), in: box, state: state)
        let closed = state.graph.count
        for _ in 0..<5 {
            _ = ViewRenderer.render(Maybe(show: true), in: box, state: state)
            _ = ViewRenderer.render(Maybe(show: false), in: box, state: state)
        }
        #expect(state.graph.count == closed)
    }
}
