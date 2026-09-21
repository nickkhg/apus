import Render
@testable import Shell
import Testing
import Toolkit

// The shell is a tree of views, so a test can draw it into a display list
// and look at the items. No screen and no compositor are needed.

/// Three apps, as the compositor reads them from /Applications.
let sampleApps = [
    AppEntry(id: "org.apus.files", name: "Files", color: Color(hex: 0x4C8DF6)),
    AppEntry(id: "org.apus.terminal", name: "Terminal", color: Color(hex: 0x3BB273)),
    AppEntry(id: "org.apus.settings", name: "Settings", color: Color(hex: 0xE0A458)),
]

/// The state of a shell with those apps.
func state(windows: [WindowEntry] = [], layout: WindowLayoutKind = .principal) -> ShellState {
    ShellState(apps: sampleApps, windows: windows, layout: layout,
               clock: Clock(hour: "14", minute: "05", weekday: "TUE"))
}

/// A window of an app, in a place on the canvas.
func window(_ id: String, app: String = "org.apus.terminal",
            title: String = "Terminal", place: WindowEntry.Place = .principal,
            focus: Bool = false) -> WindowEntry {
    WindowEntry(id: id, title: title, appID: app, place: place, hasFocus: focus)
}

private func texts(_ list: DisplayList) -> [(Bitmap, Int, Int)] {
    list.compactMap { item in
        if case .bitmap(let bitmap, let x, let y) = item { (bitmap, x, y) } else { nil }
    }
}

@Suite("The canvas")
struct AppAreaTests {
    private let screen = Rect(x: 0, y: 0, width: 1280, height: 800)

    @Test("The canvas starts beside the rail")
    func canvasStartsBesideTheRail() {
        let area = RootView.windowArea(screen: screen)
        // The gap, the rail and the gap again.
        #expect(area.x == Int(Metrics.gap + Metrics.railWidth + Metrics.gap))
        #expect(area.y == Int(Metrics.gap))
        #expect(area.x + area.width == screen.width - Int(Metrics.gap))
    }

    @Test("The canvas never covers the rail")
    func canvasNeverCoversTheRail() {
        for width in [640, 1280, 1920, 2560] {
            let area = RootView.windowArea(screen: Rect(x: 0, y: 0, width: width, height: 800))
            #expect(Double(area.x) >= Metrics.railWidth)
        }
    }

    @Test("A screen too small for the rail gives no canvas, and no negative one")
    func smallScreen() {
        // Narrower than the rail and its gaps: nothing is left across.
        let narrow = RootView.windowArea(screen: Rect(x: 0, y: 0, width: 40, height: 400))
        #expect(narrow.width == 0)
        // Shorter than the two gaps: nothing is left down.
        let short = RootView.windowArea(screen: Rect(x: 0, y: 0, width: 400, height: 8))
        #expect(short.height == 0)
    }
}


@Suite("The rail")
struct RailTests {
    private let screen = Rect(x: 0, y: 0, width: 1280, height: 800)

    private func list(_ state: ShellState) -> DisplayList {
        ViewRenderer.displayList(for: RootView(state: state), in: screen)
    }

    @Test("The rail is on the left edge and as tall as the screen")
    func railIsOnTheLeft() {
        // The rail is the first rounded rectangle that the shell draws.
        var left = Double.infinity
        var top = Double.infinity
        var bottom = 0.0
        for item in list(state()) {
            guard case .path(let path, _) = item else { continue }
            for element in path.elements {
                if case .move(let x, let y) = element {
                    left = min(left, x); top = min(top, y); bottom = max(bottom, y)
                }
                if case .line(let x, let y) = element {
                    left = min(left, x); top = min(top, y); bottom = max(bottom, y)
                }
            }
        }
        #expect(left >= Metrics.gap - 1 && left <= Metrics.gap + 1)
        #expect(top <= Metrics.gap + 1)
        #expect(bottom >= Double(screen.height) - Metrics.gap - 1)
    }

    @Test("The track has one bar for each open window")
    func oneBarForEachWindow() {
        // A bar is a rounded rectangle of the width of the track.
        func bars(_ state: ShellState) -> Int {
            var count = 0
            for item in list(state) {
                guard case .path(let path, _) = item else { continue }
                var xs: [Double] = []
                for element in path.elements {
                    switch element {
                    case .move(let x, _), .line(let x, _): xs.append(x)
                    case .cubic(_, _, _, _, let x, _): xs.append(x)
                    case .quadratic(_, _, let x, _): xs.append(x)
                    case .close: break
                    }
                }
                guard let low = xs.min(), let high = xs.max() else { continue }
                if abs((high - low) - Metrics.trackWidth) < 0.5 { count += 1 }
            }
            return count
        }
        let none = bars(state())
        let one = bars(state(windows: [window("1")]))
        let two = bars(state(windows: [window("1"), window("2", place: .widget)]))
        #expect(one == none + 1)
        #expect(two == none + 2)
    }

    @Test("A click on the Summon button opens Summon")
    func summonButtonOpens() {
        final class Log: @unchecked Sendable { var toggles = 0 }
        let log = Log()
        let actions = ShellActions(toggleSummon: { log.toggles += 1 })
        let host = ViewHost()
        let view = { RootView(state: state(), actions: actions) }
        _ = host.displayList(for: view(), in: screen)
        // The button is 40 x 40, at the gap plus 8, 16 down from the top.
        let x = Metrics.gap + 8 + Metrics.buttonSize / 2
        let y = Metrics.gap + 16 + Metrics.buttonSize / 2
        host.pointerMoved(to: x, y: y)
        _ = host.displayList(for: view(), in: screen)
        host.pointerButton(pressed: true)
        _ = host.displayList(for: view(), in: screen)
        host.pointerButton(pressed: false)
        #expect(log.toggles == 1)
    }
}

@Suite("Summon")
struct SummonTests {
    private let screen = Rect(x: 0, y: 0, width: 1280, height: 800)

    @Test("Summon is not drawn until it is open")
    func summonIsHiddenAtFirst() {
        let closed = ViewRenderer.displayList(for: RootView(state: state()), in: screen)
        var open = state()
        open.summonIsOpen = true
        let opened = ViewRenderer.displayList(for: RootView(state: open), in: screen)
        #expect(opened.count > closed.count)
    }

    @Test("An app that is not open is offered, and one that is open is not")
    func closedAppsAreOffered() {
        let groups = SummonList.groups(for: state())
        let apps = groups.first { $0.id == "apps" }
        #expect(apps?.items.count == sampleApps.count)

        let running = state(windows: [window("1", app: sampleApps[1].id)])
        let left = SummonList.groups(for: running).first { $0.id == "apps" }
        #expect(left?.items.count == sampleApps.count - 1)
    }

    @Test("An open window is listed before an app that is not open")
    func windowsComeFirst() {
        let groups = SummonList.groups(for: state(windows: [window("1")]))
        #expect(groups.first?.id == "screen")
        #expect(groups.map(\.id).firstIndex(of: "screen")! < groups.map(\.id).firstIndex(of: "apps")!)
    }

    @Test("A window that waits for a cell is in its own group")
    func waitingWindowsAreApart() {
        let groups = SummonList.groups(for: state(windows: [
            window("1"), window("2", place: .rail),
        ]))
        #expect(groups.first { $0.id == "rail" }?.items.count == 1)
        #expect(groups.first { $0.id == "screen" }?.items.count == 1)
    }

    @Test("The commands offer the layouts that are not in use")
    func commandsOfferOtherLayouts() {
        let groups = SummonList.groups(for: state(layout: .grid))
        let commands = groups.first { $0.id == "commands" }?.items ?? []
        let layouts = commands.compactMap { item -> WindowLayoutKind? in
            if case .command(.layout(let kind)) = item.kind { kind } else { nil }
        }
        #expect(layouts.count == WindowLayoutKind.allCases.count - 1)
        #expect(!layouts.contains(.grid))
    }

    @Test("Closing a window is offered only when a window is open")
    func closeIsOfferedWithAWindow() {
        func hasClose(_ state: ShellState) -> Bool {
            SummonList.groups(for: state)
                .flatMap(\.items)
                .contains { $0.kind == .command(.closeFrontWindow) }
        }
        #expect(!hasClose(state()))
        #expect(hasClose(state(windows: [window("1")])))
    }
}
