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

@Suite("The two modes")
struct AppearanceTests {
    @Test("A surface on a CPU has a line, and on a GPU it has none")
    func onlyTheCPUModeDrawsALine() {
        #expect(Appearance(.cpu).surfaceLine == 1)
        #expect(Appearance(.gpu).surfaceLine == 0)
    }

    @Test("A blur does some of the dimming, so a GPU dims less")
    func theGPUDimsLess() {
        #expect(Appearance(.gpu).dim < Appearance(.cpu).dim)
    }

    @Test("A CPU holds a larger step between one surface and the next")
    func theCPUHoldsALargerStep() {
        let cpu = Appearance(.cpu).surface
        let gpu = Appearance(.gpu).surface
        func distance(_ colour: Color) -> Double {
            abs(colour.red - Palette.desktop.red)
                + abs(colour.green - Palette.desktop.green)
                + abs(colour.blue - Palette.desktop.blue)
        }
        // The GPU surface is further from the desktop, because a shadow
        // holds it off instead of the colour doing all the work.
        #expect(distance(gpu) > distance(cpu))
    }

    @Test("Summon dims what is behind it by the amount that the mode says")
    func summonFollowsTheMode() {
        let screen = Rect(x: 0, y: 0, width: 1280, height: 800)

        /// How dark the layer under Summon is, once it has arrived.
        func dimmed(_ mode: RenderMode) -> UInt32? {
            let state = ShellState(apps: sampleApps, mode: mode, summonIsOpen: true,
                                   canvas: Rect(x: 72, y: 8, width: 1200, height: 784))
            let host = ViewHost()
            // Summon comes in. The first frame gives the move its target,
            // the second starts it, and the third is after it arrived.
            host.now = 0
            _ = host.displayList(for: RootView(state: state), in: screen)
            host.now = 1
            _ = host.displayList(for: RootView(state: state), in: screen)
            host.now = 2
            let list = host.displayList(for: RootView(state: state), in: screen)
            // The layer is a black fill across the whole screen.
            for item in list {
                if case .fill(let rect, let colour) = item,
                   rect.width >= screen.width, colour >> 24 > 0, colour & 0xFFFFFF == 0 {
                    return colour >> 24
                }
            }
            return nil
        }

        guard let cpu = dimmed(.cpu), let gpu = dimmed(.gpu) else {
            Issue.record("Summon drew no layer under it")
            return
        }
        #expect(cpu > gpu)
    }

    @Test("Summon draws no layer on the frame that it opens")
    func summonComesIn() {
        let state = ShellState(apps: sampleApps, summonIsOpen: true,
                               canvas: Rect(x: 72, y: 8, width: 1200, height: 784))
        let host = ViewHost()
        host.now = 0
        let first = host.displayList(for: RootView(state: state),
                                     in: Rect(x: 0, y: 0, width: 1280, height: 800))
        host.now = 1
        _ = host.displayList(for: RootView(state: state),
                             in: Rect(x: 0, y: 0, width: 1280, height: 800))
        host.now = 2
        let later = host.displayList(for: RootView(state: state),
                                     in: Rect(x: 0, y: 0, width: 1280, height: 800))
        #expect(later.count > first.count)
    }
}
