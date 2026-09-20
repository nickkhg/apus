import Render
import Testing
@testable import Shell
@testable import Toolkit

// These tests are the behaviour of the layouts, written down. Each one is a
// rule of the design: what a layout proposes, what it does with the answer,
// and which windows it does not place. A window that a layout does not place
// waits in the rail.

/// A window that wants `ideal` along the axis that the proposal leaves free,
/// and takes what the proposal sets. An app of the toolkit answers this way.
private func app(_ ideal: Double, id: Int = 0) -> LayoutSubview {
    LayoutSubview(id: id) { proposal in
        Size(width: proposal.width ?? ideal, height: proposal.height ?? ideal)
    }
}

/// A window that wants one size whatever the proposal says. A foreign app
/// that sent a minimum size answers this way.
private func stubborn(_ size: Size, id: Int = 0) -> LayoutSubview {
    LayoutSubview(id: id) { _ in size }
}

private func canvas(_ width: Double, _ height: Double) -> Frame {
    Frame(x: 0, y: 0, width: width, height: height)
}

/// The canvas of a 1280 x 800 screen, after the rail and the gaps.
private let laptop = canvas(1200, 784)

@Suite("The size class")
struct SizeClassTests {
    @Test("A tile is a widget")
    func aTileIsAWidget() {
        #expect(SizeClass.of(Proposal(width: 256, height: 384)) == .widget)
        #expect(SizeClass.of(Proposal(width: 320, height: 900)) == .widget)
    }

    @Test("Half of a screen is compact")
    func halfAScreenIsCompact() {
        #expect(SizeClass.of(Proposal(width: 596, height: 784)) == .compact)
        #expect(SizeClass.of(Proposal(width: 640, height: 480)) == .compact)
    }

    @Test("The large cell is large")
    func theLargeCellIsLarge() {
        #expect(SizeClass.of(Proposal(width: 936, height: 784)) == .large)
        #expect(SizeClass.of(Proposal(width: 641, height: 641)) == .large)
    }

    @Test("A proposal with no size at all is large")
    func noSizeIsLarge() {
        #expect(SizeClass.of(.unspecified) == .large)
    }

    @Test("The shorter side decides, not the longer one")
    func theShorterSideDecides() {
        #expect(SizeClass.of(Proposal(width: 256, height: 2000)) == .widget)
    }
}

@Suite("The length of a tile")
struct TileLengthTests {
    @Test("An answer goes up to a whole step")
    func anAnswerGoesUpToAStep() {
        // 341 is what a file list wants; a tile is a number of 64s.
        #expect(WindowMetrics.tileLength(for: 341) == 384)
        #expect(WindowMetrics.tileLength(for: 256) == 256)
        #expect(WindowMetrics.tileLength(for: 200) == 256)
    }

    @Test("A window that wants very little still gets a usable tile")
    func aSmallAnswerIsClampedUp() {
        #expect(WindowMetrics.tileLength(for: 40) == WindowMetrics.shortestTile)
        #expect(WindowMetrics.tileLength(for: 0) == WindowMetrics.shortestTile)
    }

    @Test("A window that wants more than the longest tile gets none")
    func aLargeAnswerGetsNoTile() {
        #expect(WindowMetrics.tileLength(for: 400) == nil)
        #expect(WindowMetrics.tileLength(for: 785) == nil)
    }
}

@Suite("Principal and widgets")
struct PrincipalAndWidgetsTests {
    private let layout = PrincipalAndWidgets()

    @Test("One window takes the whole canvas")
    func oneWindowTakesEverything() {
        let frames = layout.frames(in: laptop, subviews: LayoutSubviews([app(400)]))
        #expect(frames[0] == laptop)
    }

    @Test("A second window makes the band, and the large cell is 936 wide")
    func aSecondWindowMakesTheBand() {
        let frames = layout.frames(in: laptop, subviews: LayoutSubviews([app(400), app(256, id: 1)]))
        #expect(frames[0] == Frame(x: 0, y: 0, width: 936, height: 784))
        // The band is one column of 256, on the right, starting at the top.
        #expect(frames[1] == Frame(x: 944, y: 0, width: 256, height: 256))
    }

    @Test("A tile is as long as the window answered, in whole steps")
    func aTileTakesTheAnswer() {
        let frames = layout.frames(in: laptop,
                                   subviews: LayoutSubviews([app(400), app(341, id: 1)]))
        #expect(frames[1]?.height == 384)
        #expect(frames[1]?.width == 256)
    }

    @Test("Tiles stack from the top and do not stretch")
    func tilesStackFromTheTop() {
        let frames = layout.frames(in: laptop, subviews: LayoutSubviews([
            app(400), app(384, id: 1), app(256, id: 2), app(192, id: 3),
        ]))
        #expect(frames[1] == Frame(x: 944, y: 0, width: 256, height: 384))
        #expect(frames[2] == Frame(x: 944, y: 392, width: 256, height: 256))
        // 384 + 8 + 256 + 8 = 656, and 192 more is 848, past the 784 canvas.
        #expect(frames[3] == nil)
    }

    @Test("A window that cannot use a tile is not placed")
    func aStubbornWindowIsNotPlaced() {
        // A foreign app that sent a minimum of 600 x 400 cannot fit a tile.
        let frames = layout.frames(in: laptop, subviews: LayoutSubviews([
            app(400), stubborn(Size(width: 600, height: 400), id: 1), app(256, id: 2),
        ]))
        #expect(frames[1] == nil)
        // The window after it still gets the free tile.
        #expect(frames[2] == Frame(x: 944, y: 0, width: 256, height: 256))
    }

    @Test("A window that needs more width than a tile gives is not placed")
    func aWideWindowIsNotPlaced() {
        // A foreign app with a minimum of 600 x 100 is short enough for a
        // tile but far too wide for one.
        let frames = layout.frames(in: laptop, subviews: LayoutSubviews([
            app(400), stubborn(Size(width: 600, height: 100), id: 1),
        ]))
        #expect(frames[1] == nil)
    }

    @Test("A wider screen gets more band columns")
    func aWiderScreenGetsMoreColumns() {
        func columns(_ width: Double) -> Int {
            let windows = [app(400)] + (1...12).map { app(384, id: $0) }
            let frames = layout.frames(in: canvas(width, 784), subviews: LayoutSubviews(windows))
            return Set(frames.dropFirst().compactMap { $0?.x }).count
        }
        #expect(columns(1200) == 1)
        #expect(columns(1840) == 2)
        #expect(columns(2480) == 3)
    }

    @Test("The large cell never goes under its smallest size")
    func theLargeCellKeepsItsSpace() {
        let windows = [app(400)] + (1...12).map { app(384, id: $0) }
        for width in [1200.0, 1840, 2480] {
            let frames = layout.frames(in: canvas(width, 784), subviews: LayoutSubviews(windows))
            #expect((frames[0]?.width ?? 0) >= WindowMetrics.principalMinimum)
        }
    }

    @Test("A tall screen puts the band along the bottom")
    func aTallScreenPutsTheBandBelow() {
        let frames = layout.frames(in: canvas(784, 1200),
                                   subviews: LayoutSubviews([app(400), app(256, id: 1)]))
        // The large cell is at the top and the tile is under it.
        #expect(frames[0]?.width == 784)
        #expect(frames[1]?.height == 256)
        #expect((frames[1]?.y ?? 0) > (frames[0]?.height ?? 0) - 1)
    }

    @Test("No window places nothing")
    func noWindowPlacesNothing() {
        #expect(layout.frames(in: laptop, subviews: LayoutSubviews([])).isEmpty)
    }
}

@Suite("Side by side")
struct SideBySideTests {
    private let layout = SideBySide()

    @Test("Two windows share the canvas")
    func twoWindowsShare() {
        let frames = layout.frames(in: laptop,
                                   subviews: LayoutSubviews([app(400), app(400, id: 1)]))
        #expect(frames[0] == Frame(x: 0, y: 0, width: 596, height: 784))
        #expect(frames[1] == Frame(x: 604, y: 0, width: 596, height: 784))
    }

    @Test("Every window after the second waits in the rail")
    func theThirdWindowWaits() {
        let frames = layout.frames(in: laptop, subviews: LayoutSubviews([
            app(400), app(400, id: 1), app(400, id: 2),
        ]))
        #expect(frames[2] == nil)
    }

    @Test("It proposes a half to each window, whatever the window answers")
    func theFrameHoldsAgainstTheAnswer() {
        let frames = layout.frames(in: laptop, subviews: LayoutSubviews([
            stubborn(Size(width: 100, height: 100)), stubborn(Size(width: 5000, height: 5000), id: 1),
        ]))
        #expect(frames[0]?.width == 596)
        #expect(frames[1]?.width == 596)
    }
}

@Suite("The grid")
struct GridLayoutTests {
    private let layout = GridLayout()

    @Test("The grid is as square as the count allows")
    func theShapeIsSquare() {
        #expect(GridLayout.shape(for: 1) == (1, 1))
        #expect(GridLayout.shape(for: 2) == (2, 1))
        #expect(GridLayout.shape(for: 4) == (2, 2))
        #expect(GridLayout.shape(for: 5) == (3, 2))
        #expect(GridLayout.shape(for: 9) == (3, 3))
    }

    @Test("Four windows make four cells of the same size")
    func fourCells() {
        let windows = (0..<4).map { app(400, id: $0) }
        let frames = layout.frames(in: laptop, subviews: LayoutSubviews(windows))
        let sizes = Set(frames.compactMap { $0.map { "\($0.width)x\($0.height)" } })
        #expect(sizes.count == 1)
        #expect(frames[0]?.x == 0 && frames[0]?.y == 0)
        #expect(frames[3]?.x == frames[1]?.x)
        #expect(frames[3]?.y == frames[2]?.y)
    }

    @Test("A cell of a full grid is small enough to be a widget")
    func aFullGridCellIsAWidget() {
        let windows = (0..<9).map { app(400, id: $0) }
        let frames = layout.frames(in: laptop, subviews: LayoutSubviews(windows))
        guard let cell = frames[0] else {
            Issue.record("expected a cell")
            return
        }
        #expect(SizeClass.of(Proposal(cell.size)) == .widget)
    }

    @Test("Every window after the ninth waits in the rail")
    func theTenthWindowWaits() {
        let windows = (0..<10).map { app(400, id: $0) }
        let frames = layout.frames(in: laptop, subviews: LayoutSubviews(windows))
        #expect(frames[9] == nil)
        #expect(frames[8] != nil)
    }
}

@Suite("Full")
struct FullScreenTests {
    @Test("The first window takes the canvas and the rest wait")
    func oneWindowOnly() {
        let frames = FullScreen().frames(in: laptop, subviews: LayoutSubviews([
            app(400), app(400, id: 1),
        ]))
        #expect(frames[0] == laptop)
        #expect(frames[1] == nil)
    }
}
