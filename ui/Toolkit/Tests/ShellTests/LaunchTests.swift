import Render
@testable import Shell
import Testing
import Toolkit

// A launch holds a cell from the moment a person chooses an app. An app that
// never opens a window leaves its reason in that cell.

@Suite("A launch")
struct LaunchTests {
    private let screen = Rect(x: 0, y: 0, width: 1280, height: 800)
    private let cell = Rect(x: 72, y: 8, width: 1200, height: 784)

    private func launch(_ state: Launch.State) -> Launch {
        // The mark of the app is deliberately not the failure colour, so
        // that a test for the failure colour cannot pass by accident.
        Launch(id: "l1", appName: "Broken", mark: Color(hex: 0x4C8DF6),
               command: "/bin/true", state: state, frame: cell)
    }

    private func items(_ launch: Launch) -> DisplayList {
        ViewRenderer.displayList(for: LaunchCard(launch: launch),
                                 in: Rect(x: 0, y: 0, width: cell.width, height: cell.height))
    }

    @Test("A launch that failed says so, and one that is starting does not")
    func theStateShows() {
        func texts(_ list: DisplayList) -> Int {
            list.count { if case .bitmap = $0 { true } else { false } }
        }
        // A failure names the reason, the command and two controls, so it
        // draws more text than a launch that is still going.
        #expect(texts(items(launch(.failed("It ran, and it opened no window."))))
                > texts(items(launch(.starting))))
    }

    @Test("A cell that failed has the failure colour around it")
    func aFailureIsRed() {
        /// The line around the cell is a path in the colour of the state.
        func borders(_ list: DisplayList) -> [UInt32] {
            list.compactMap { if case .path(_, let colour) = $0 { colour } else { nil } }
        }
        #expect(borders(items(launch(.failed("no window"))))
            .contains(Palette.error.premultiplied))
        // A cell that is still starting has no failure colour anywhere.
        #expect(!borders(items(launch(.starting))).contains(Palette.error.premultiplied))
    }

    @Test("The canvas does not say that nothing is open while an app starts")
    func aStartingAppIsNotNothing() {
        func texts(_ state: ShellState) -> Int {
            ViewRenderer.displayList(for: RootView(state: state), in: screen)
                .count { if case .bitmap = $0 { true } else { false } }
        }
        let nothing = ShellState(apps: sampleApps, canvas: cell)
        var starting = nothing
        starting.launches = [launch(.starting)]
        // The two draw different things: one says how to start an app, the
        // other says that an app is starting.
        #expect(texts(nothing) != texts(starting))
    }

    @Test("The control of a failed cell asks the compositor to take it away")
    func theControlsWork() {
        final class Log: @unchecked Sendable {
            var retried: [String] = []
            var dismissed: [String] = []
        }
        let log = Log()
        let actions = ShellActions(retryLaunch: { log.retried.append($0) },
                                   dismissLaunch: { log.dismissed.append($0) })
        let card = launch(.failed("no window"))
        let box = Rect(x: 0, y: 0, width: cell.width, height: cell.height)
        let pass = ViewRenderer.render(LaunchCard(launch: card, actions: actions), in: box)
        // Two controls: try again, and close.
        #expect(pass.tapRegions.count == 2)

        let host = ViewHost()
        let view = { LaunchCard(launch: card, actions: actions) }
        _ = host.displayList(for: view(), in: box)
        guard let first = pass.tapRegions.first else { return }
        host.pointerMoved(to: first.frame.x + 1, y: first.frame.y + 1)
        _ = host.displayList(for: view(), in: box)
        host.pointerButton(pressed: true)
        _ = host.displayList(for: view(), in: box)
        host.pointerButton(pressed: false)
        #expect(log.retried == ["l1"])
        #expect(log.dismissed.isEmpty)
    }

    @Test("A launch that is still going has no controls")
    func aStartingCellHasNoControls() {
        let box = Rect(x: 0, y: 0, width: cell.width, height: cell.height)
        let pass = ViewRenderer.render(LaunchCard(launch: launch(.starting)), in: box)
        #expect(pass.tapRegions.isEmpty)
    }
}
