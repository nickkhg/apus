import Render
@testable import Shell
import Testing
import Toolkit

// The panel is a view, so a test can draw it into a display list and look at
// the items. No screen and no compositor are needed.

private func items(_ state: ShellState, width: Int = 1280) -> DisplayList {
    ViewRenderer.displayList(for: Panel(state: state),
                             in: Rect(x: 0, y: 0, width: width, height: Int(Panel.height)))
}

/// Three apps, as the compositor reads them from /Applications.
let sampleApps = [
    AppEntry(id: "org.mydistro.files", name: "Files", color: Color(hex: 0x4C8DF6)),
    AppEntry(id: "org.mydistro.terminal", name: "Terminal", color: Color(hex: 0x3BB273)),
    AppEntry(id: "org.mydistro.settings", name: "Settings", color: Color(hex: 0xE0A458)),
]

/// The state of a shell with those apps.
func state(running: Set<String> = [], windowTitles: [String] = []) -> ShellState {
    ShellState(apps: sampleApps, runningApps: running,
               windowTitles: windowTitles, clock: "14:05")
}

private func texts(_ list: DisplayList) -> [(Bitmap, Int, Int)] {
    list.compactMap { item in
        if case .bitmap(let bitmap, let x, let y) = item { (bitmap, x, y) } else { nil }
    }
}

@Suite("Panel")
struct PanelTests {
    @Test("The panel fills the bar with its background colour")
    func backgroundFillsTheBar() {
        let list = items(ShellState(clock: "14:05"))
        guard case .fill(let rect, let color) = list.first else {
            Issue.record("the first item is not a fill: \(list.first as Any)")
            return
        }
        #expect(rect == Rect(x: 0, y: 0, width: 1280, height: 28))
        #expect(color == 0xFF1B1626)
    }

    @Test("The panel shows the name and the time, and nothing else when no window is open")
    func nameAndClock() {
        let list = items(ShellState(clock: "14:05"))
        #expect(texts(list).count == 2)
    }

    @Test("The panel shows the title of the front window, and a close button")
    func windowTitle() {
        let list = items(ShellState(windowTitles: ["first", "second"], clock: "14:05"))
        // The name, the title, the title of the button, and the time.
        #expect(texts(list).count == 4)
    }

    @Test("The close button asks the compositor to close the front window")
    func closeButtonCallsTheAction() {
        final class Counter { var closes = 0 }
        let counter = Counter()
        let actions = ShellActions(closeFrontWindow: { counter.closes += 1 })
        let host = ViewHost()
        let panel = Rect(x: 0, y: 0, width: 1280, height: Int(Panel.height))
        let list = host.displayList(
            for: Panel(state: ShellState(windowTitles: ["a window"], clock: "14:05"),
                       actions: actions),
            in: panel)
        // The button is left of the time, at the right end of the panel.
        var button: Rect?
        for item in list {
            if case .path(let path, _) = item {
                for element in path.elements {
                    if case .move(let x, let y) = element { button = Rect(x: Int(x), y: Int(y), width: 0, height: 0) }
                }
            }
        }
        guard let button else {
            Issue.record("the panel has no button")
            return
        }
        host.pointerMoved(to: Double(button.x) + 20, y: Double(button.y) + 6)
        host.pointerButton(pressed: true)
        host.pointerButton(pressed: false)
        #expect(counter.closes == 1)
    }

    @Test("The name is on the left and the time is on the right")
    func nameLeftClockRight() {
        let width = 1280
        let list = items(ShellState(clock: "14:05"), width: width)
        let drawn = texts(list)
        guard drawn.count == 2 else {
            Issue.record("expected two pieces of text, got \(drawn.count)")
            return
        }
        let (name, clock) = (drawn[0], drawn[1])
        #expect(name.1 == 12, "the name starts after the padding")
        #expect(clock.1 + clock.0.width == width - 12, "the time ends before the padding")
    }

    @Test("The text sits inside the bar")
    func textInsideTheBar() {
        for (bitmap, _, y) in texts(items(ShellState(windowTitles: ["window"], clock: "14:05"))) {
            #expect(y >= 0)
            #expect(y + bitmap.height <= Int(Panel.height))
        }
    }

    @Test("An empty title adds no text")
    func emptyTitle() {
        // The name, the title of the close button, and the time.
        #expect(texts(items(ShellState(windowTitles: [""], clock: "14:05"))).count == 3)
    }
}

@Suite("Dock")
struct DockTests {
    private let screen = Rect(x: 0, y: 0, width: 1280, height: 800)

    /// The paths of a view, with the size of each one.
    private func paths(_ view: some View) -> [(width: Double, height: Double)] {
        ViewRenderer.displayList(for: view, in: screen).compactMap { item in
            guard case .path(let path, _) = item else { return nil }
            var xs: [Double] = []
            var ys: [Double] = []
            for element in path.elements {
                switch element {
                case .move(let x, let y), .line(let x, let y): xs.append(x); ys.append(y)
                case .quadratic(_, _, let x, let y): xs.append(x); ys.append(y)
                case .cubic(_, _, _, _, let x, let y): xs.append(x); ys.append(y)
                case .close: break
                }
            }
            return ((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
        }
    }

    @Test("The dock is as large as its icons, not as large as the screen")
    func dockKeepsItsSize() {
        let shapes = paths(DockView(apps: sampleApps))
        // One background and three icons. The dots of the apps that are not
        // open are clear, and a clear shape draws nothing.
        #expect(shapes.count == 4)
        for icon in shapes.dropFirst() {
            #expect(icon == (width: 44, height: 44))
        }
        let background = shapes[0]
        #expect(background.width == 44 * 3 + 10 * 2 + 20)
        // The icon, the space under it, the dot, and the padding.
        #expect(background.height == 44 + 4 + 5 + 20)
        #expect(background.height == DockView.height)
    }

    @Test("A dock with no app draws nothing")
    func emptyDockDrawsNothing() {
        #expect(paths(DockView(apps: [])).isEmpty)
    }

    @Test("The dock is at the bottom of the screen, under the panel")
    func dockIsAtTheBottom() {
        let list = ViewRenderer.displayList(for: RootView(state: state()), in: screen)
        var lowest = 0.0
        for item in list {
            guard case .path(let path, _) = item else { continue }
            for element in path.elements {
                if case .line(_, let y) = element { lowest = max(lowest, y) }
            }
        }
        #expect(lowest > 700 && lowest <= 800 - 16)
    }
}

@Suite("The app area")
struct AppAreaTests {
    private let screen = Rect(x: 0, y: 0, width: 1280, height: 800)

    @Test("The app area starts under the panel and fills the width")
    func areaIsUnderThePanel() {
        let area = RootView.windowArea(screen: screen)
        #expect(area.x == 0)
        #expect(area.y == Int(Panel.height))
        #expect(area.width == screen.width)
    }

    @Test("The app area stops over the dock")
    func areaStopsOverTheDock() {
        let list = ViewRenderer.displayList(for: RootView(state: state()), in: screen)
        // The first path is the background of the dock. Its top is the
        // highest point that the dock draws.
        var dockTop = Double(screen.height)
        for item in list {
            guard case .path(let path, _) = item else { continue }
            for element in path.elements {
                switch element {
                case .move(_, let y), .line(_, let y): dockTop = min(dockTop, y)
                case .quadratic(_, _, _, let y): dockTop = min(dockTop, y)
                case .cubic(_, _, _, _, _, let y): dockTop = min(dockTop, y)
                case .close: break
                }
            }
        }
        let area = RootView.windowArea(screen: screen)
        #expect(Double(area.y + area.height) <= dockTop)
    }

    @Test("A small screen gives no app area, and no negative one")
    func smallScreen() {
        let area = RootView.windowArea(screen: Rect(x: 0, y: 0, width: 200, height: 40))
        #expect(area.height == 0)
    }
}

@Suite("Dock clicks")
struct DockClickTests {
    private let screen = Rect(x: 0, y: 0, width: 1280, height: 800)

    /// The middle of the first dock icon. The dock is in the middle of the
    /// screen at the bottom: 172 wide, and the first icon starts after the
    /// padding of 10.
    private let firstIcon = (x: 1280.0 / 2 - 172 / 2 + 10 + 22,
                             y: 800.0 - DockView.bottomMargin - DockView.height + 10 + 22)

    @Test("A click on a dock icon asks the compositor to open the app")
    func clickOpensTheApp() {
        final class Log { var opened: [String] = [] }
        let log = Log()
        let actions = ShellActions(openApp: { log.opened.append($0) })
        let host = ViewHost()
        func draw() {
            _ = host.displayList(for: RootView(state: state(), actions: actions), in: screen)
        }
        host.needsUpdate = { draw() }
        draw()

        host.pointerMoved(to: firstIcon.x, y: firstIcon.y)
        host.pointerButton(pressed: true)
        host.pointerButton(pressed: false)
        #expect(log.opened == [sampleApps[0].id])

        // The shell asks again for an app that is open already. The
        // compositor then brings the window to the front.
        host.pointerButton(pressed: true)
        host.pointerButton(pressed: false)
        #expect(log.opened == [sampleApps[0].id, sampleApps[0].id])
    }

    @Test("An open app has a dot under its icon")
    func openAppHasADot() {
        /// The dots are the small shapes. A dot that draws nothing is clear.
        func dots(_ list: DisplayList) -> Int {
            list.filter { item in
                guard case .path(let path, _) = item else { return false }
                var ys: [Double] = []
                for element in path.elements {
                    if case .cubic(_, _, _, _, _, let y) = element { ys.append(y) }
                }
                guard let low = ys.min(), let high = ys.max() else { return false }
                return high - low < 8
            }.count
        }

        let closed = ViewRenderer.displayList(for: RootView(state: state()), in: screen)
        #expect(dots(closed) == 0, "no app is open")

        let open = ViewRenderer.displayList(
            for: RootView(state: state(running: [sampleApps[1].id])), in: screen)
        #expect(dots(open) == 1)
    }
}
