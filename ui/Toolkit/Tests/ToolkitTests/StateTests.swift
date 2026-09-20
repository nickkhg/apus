import Render
import Testing
@testable import Toolkit

// @State keeps a value from one frame to the next. These tests draw the same
// view several times with one ViewState, as the compositor does.

private struct Counter: View {
    @State var count = 0
    let width: Double

    var body: some View {
        Color(hex: 0x000000 + UInt32(count)).frame(width: width, height: 10)
    }
}

/// The colour of the first fill says which value the state has. These tests
/// carry a number in a colour, so the alpha byte of the fill is dropped.
private func value(_ list: DisplayList) -> UInt32? {
    for item in list {
        if case .fill(_, let color) = item { return color & 0x00FF_FFFF }
    }
    return nil
}

@Suite("State")
struct StateTests {
    @Test("A state value stays from one frame to the next")
    func stateSurvivesAFrame() {
        let state = ViewState()
        let rect = Rect(x: 0, y: 0, width: 100, height: 100)
        let counter = Counter(width: 10)

        _ = ViewRenderer.render(counter, in: rect, state: state)
        counter.count = 7
        let second = ViewRenderer.render(Counter(width: 10), in: rect, state: state)
        #expect(value(second.list) == 7)
    }

    @Test("Without a store, each frame starts again")
    func withoutAStoreTheValueGoesAway() {
        let rect = Rect(x: 0, y: 0, width: 100, height: 100)
        let counter = Counter(width: 10)
        _ = ViewRenderer.render(counter, in: rect)
        counter.count = 7
        #expect(value(ViewRenderer.render(Counter(width: 10), in: rect).list) == 0)
    }

    @Test("A change asks for a new frame")
    func aChangeAsksForAFrame() {
        let state = ViewState()
        var updates = 0
        state.needsUpdate = { updates += 1 }
        let counter = Counter(width: 10)
        _ = ViewRenderer.render(counter, in: Rect(x: 0, y: 0, width: 100, height: 100), state: state)
        #expect(updates == 0)
        counter.count = 1
        #expect(updates == 1)
    }

    @Test("Two views of the same type have their own state")
    func siblingsDoNotShareState() {
        struct Two: View {
            var body: some View {
                HStack {
                    Counter(width: 10)
                    Counter(width: 20)
                }
            }
        }
        let state = ViewState()
        let rect = Rect(x: 0, y: 0, width: 100, height: 100)
        _ = ViewRenderer.render(Two(), in: rect, state: state)
        #expect(state.count == 2)
    }

    @Test("The state of a view that goes away is removed")
    func stateOfARemovedViewGoesAway() {
        struct Maybe: View {
            let show: Bool
            var body: some View {
                VStack {
                    if show { Counter(width: 10) }
                    Color.red.frame(width: 5, height: 5)
                }
            }
        }
        let state = ViewState()
        let rect = Rect(x: 0, y: 0, width: 100, height: 100)
        _ = ViewRenderer.render(Maybe(show: true), in: rect, state: state)
        #expect(state.count == 1)
        _ = ViewRenderer.render(Maybe(show: false), in: rect, state: state)
        #expect(state.count == 0)
    }

    @Test("A binding writes the value of the view that owns it")
    func bindingWritesTheOwnersValue() {
        struct Child: View {
            @Binding var count: Int
            var body: some View { Color.red.frame(width: Double(count), height: 10) }
        }
        struct Parent: View {
            @State var count = 3
            var body: some View { Child(count: $count) }
        }
        let state = ViewState()
        let rect = Rect(x: 0, y: 0, width: 100, height: 100)
        let parent = Parent()
        let list = ViewRenderer.render(parent, in: rect, state: state).list
        if case .fill(let frame, _) = list.first { #expect(frame.width == 3) }
        parent.count = 8
        let second = ViewRenderer.render(Parent(), in: rect, state: state).list
        if case .fill(let frame, _) = second.first { #expect(frame.width == 8) }
    }

    @Test("The state of a row follows the row when the rows change order")
    func stateFollowsAForEachIdentity() {
        struct Row: View {
            let name: String
            @State var mark = 0
            var body: some View { Color(hex: UInt32(mark)).frame(width: 10, height: 10) }
        }
        struct List: View {
            let names: [String]
            var body: some View {
                VStack { ForEach(names, id: \.self) { Row(name: $0) } }
            }
        }
        let state = ViewState()
        let rect = Rect(x: 0, y: 0, width: 100, height: 100)
        let rowA = Row(name: "a")
        let rowB = Row(name: "b")
        func list(_ names: [String]) -> some View {
            VStack { ForEach(names, id: \.self) { name in name == "a" ? rowA : rowB } }
        }

        // The first frame connects the state of both rows.
        _ = ViewRenderer.render(list(["a", "b"]), in: rect, state: state)
        rowB.mark = 0x0000FF

        // "b" is now first, and its colour goes with it.
        let drawn = ViewRenderer.render(list(["b", "a"]), in: rect, state: state).list
        #expect(value(drawn) == 0x0000FF)
    }
}
