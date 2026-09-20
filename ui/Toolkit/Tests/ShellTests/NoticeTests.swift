import Render
@testable import Shell
import Testing
import Toolkit

// A notice never covers the window in the large cell: it goes where a tile
// would go, at the end of the band.

@Suite("Notices")
struct NoticeTests {
    private let screen = Rect(x: 0, y: 0, width: 1280, height: 800)
    private let canvas = Rect(x: 72, y: 8, width: 1200, height: 784)

    private func state(_ notices: [Notice], windows: [WindowEntry] = []) -> ShellState {
        ShellState(apps: sampleApps, windows: windows, notices: notices, canvas: canvas)
    }

    private func notice(_ id: String, kind: Notice.Kind = .information,
                        detail: String = "") -> Notice {
        Notice(id: id, kind: kind, source: "Terminal", title: "Something happened",
               detail: detail)
    }

    @Test("A notice goes where a tile would go, not over the large cell")
    func aNoticeStaysOutOfTheLargeCell() {
        let places = RootView(state: state([notice("a")])).noticePlaces
        #expect(places.count == 1)
        guard let frame = places.first?.frame else { return }
        // The band is the last 256 points of the canvas.
        #expect(frame.x == canvas.x + canvas.width - Int(WindowMetrics.tile))
        #expect(frame.width == Int(WindowMetrics.tile))
        // And it sits at the bottom of the canvas.
        #expect(frame.y + frame.height <= canvas.y + canvas.height)
    }

    @Test("The newest notice is the lowest one")
    func theNewestIsLowest() {
        let places = RootView(state: state([notice("old"), notice("new")])).noticePlaces
        #expect(places.count == 2)
        guard let first = places.first, let second = places.last else { return }
        #expect(first.notice.id == "new")
        #expect(first.frame.y > second.frame.y)
    }

    @Test("A notice with more to say is taller")
    func detailMakesItTaller() {
        #expect(NoticeView.height(of: notice("a", detail: "and why"))
                > NoticeView.height(of: notice("a")))
    }

    @Test("A canvas too narrow for the band shows no notice")
    func anarrowCanvasShowsNone() {
        var small = state([notice("a")])
        small.canvas = Rect(x: 0, y: 0, width: 100, height: 400)
        #expect(RootView(state: small).noticePlaces.isEmpty)
    }

    @Test("No more notices are placed than the canvas has room for")
    func theColumnStopsAtTheTop() {
        let many = (0..<40).map { notice("n\($0)") }
        let places = RootView(state: state(many)).noticePlaces
        #expect(places.count < many.count)
        #expect(places.allSatisfy { $0.frame.y >= canvas.y })
    }

    @Test("Each kind has a colour of its own")
    func eachKindHasAColour() {
        let colours = [Notice.Kind.information, .warning, .failure].map(\.color.packed)
        #expect(Set(colours).count == 3)
    }

    @Test("The canvas says how to start an app when nothing is open")
    func theEmptyCanvasSaysWhatToDo() {
        func texts(_ state: ShellState) -> Int {
            ViewRenderer.displayList(for: RootView(state: state), in: screen)
                .count { if case .bitmap = $0 { true } else { false } }
        }
        let empty = texts(state([]))
        let open = texts(state([], windows: [window("1")]))
        #expect(empty > open)
    }
}
