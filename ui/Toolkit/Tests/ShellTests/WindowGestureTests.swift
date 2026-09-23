import Render
import Testing
@testable import Shell
@testable import Toolkit

// A move and a resize on a canvas that a layout owns. The compositor reads
// xdg_toplevel.move and xdg_toplevel.resize through these rules, so these
// tests are the rules of window management, written down.

private let laptop = Frame(x: 72, y: 8, width: 1200, height: 784)
private let tall = Frame(x: 72, y: 8, width: 784, height: 1200)

@Suite("A resize")
struct WindowResizeTests {
    @Test("The large cell has no edge of its own")
    func thePrincipalIsRefused() {
        for edges: WindowEdges in [.right, .bottom, [.bottom, .right], .left, .top] {
            #expect(WindowResize.of(layout: .principal, index: 0, placed: true,
                                    edges: edges, canvas: laptop) == nil)
        }
    }

    @Test("A tile changes its length along the band, and not its width")
    func aTileChangesItsLength() {
        // A wide screen stacks the tiles in a column, so the length is the
        // height.
        #expect(WindowResize.of(layout: .principal, index: 1, placed: true,
                                edges: .bottom, canvas: laptop)
                == .tileLength(axis: .vertical, sign: 1))
        #expect(WindowResize.of(layout: .principal, index: 2, placed: true,
                                edges: .top, canvas: laptop)
                == .tileLength(axis: .vertical, sign: -1))
        #expect(WindowResize.of(layout: .principal, index: 1, placed: true,
                                edges: [.bottom, .left], canvas: laptop)
                == .tileLength(axis: .vertical, sign: 1))
        #expect(WindowResize.of(layout: .principal, index: 1, placed: true,
                                edges: .left, canvas: laptop) == nil)
        // A tall screen puts the band in a row, so the length is the width.
        #expect(WindowResize.of(layout: .principal, index: 1, placed: true,
                                edges: .right, canvas: tall)
                == .tileLength(axis: .horizontal, sign: 1))
        #expect(WindowResize.of(layout: .principal, index: 1, placed: true,
                                edges: .bottom, canvas: tall) == nil)
    }

    @Test("A window in the rail has no edge to move")
    func aWindowInTheRailIsRefused() {
        #expect(WindowResize.of(layout: .principal, index: 3, placed: false,
                                edges: .bottom, canvas: laptop) == nil)
    }

    @Test("Side by side, only the edge between the two windows moves")
    func onlyTheInnerEdge() {
        #expect(WindowResize.of(layout: .sideBySide, index: 0, placed: true,
                                edges: .right, canvas: laptop) == .split)
        #expect(WindowResize.of(layout: .sideBySide, index: 0, placed: true,
                                edges: [.top, .right], canvas: laptop) == .split)
        #expect(WindowResize.of(layout: .sideBySide, index: 1, placed: true,
                                edges: .left, canvas: laptop) == .split)
        #expect(WindowResize.of(layout: .sideBySide, index: 0, placed: true,
                                edges: .left, canvas: laptop) == nil)
        #expect(WindowResize.of(layout: .sideBySide, index: 1, placed: true,
                                edges: .right, canvas: laptop) == nil)
        #expect(WindowResize.of(layout: .sideBySide, index: 0, placed: true,
                                edges: .bottom, canvas: laptop) == nil)
    }

    @Test("A grid cell and a full window keep the size that the layout gives")
    func gridAndFullAreRefused() {
        for layout: WindowLayoutKind in [.grid, .full] {
            #expect(WindowResize.of(layout: layout, index: 0, placed: true,
                                    edges: [.bottom, .right], canvas: laptop) == nil)
        }
    }

    @Test("A tile snaps to a whole step, between the shortest and the longest tile")
    func aTileSnaps() {
        #expect(WindowResize.tileLength(from: 256, moved: 20, sign: 1) == 256)
        #expect(WindowResize.tileLength(from: 256, moved: 40, sign: 1) == 320)
        #expect(WindowResize.tileLength(from: 256, moved: 100, sign: 1) == 384)
        #expect(WindowResize.tileLength(from: 256, moved: 100, sign: -1) == 192)
        // However far the pointer goes, the window keeps its tile.
        #expect(WindowResize.tileLength(from: 256, moved: 900, sign: 1)
                == WindowMetrics.longestTile)
        #expect(WindowResize.tileLength(from: 256, moved: -900, sign: 1)
                == WindowMetrics.shortestTile)
        // Every length it gives is one that the band takes as it is.
        for moved in stride(from: -300.0, through: 300, by: 7) {
            let length = WindowResize.tileLength(from: 256, moved: moved, sign: 1)
            #expect(WindowMetrics.tileLength(for: length) == length)
        }
    }
}

@Suite("A move")
struct WindowMoveTests {
    // Two windows in the principal layout on a laptop: the large cell and
    // the first tile of the band. The third waits in the rail.
    private let cells: [Rect?] = [
        Rect(x: 72, y: 8, width: 936, height: 784),
        Rect(x: 1016, y: 8, width: 256, height: 256),
        nil,
    ]

    @Test("A window dropped on another cell takes that place")
    func aDropOnAnotherCell() {
        #expect(WindowMove.target(at: (1100, 100), cells: cells, moving: 0) == 1)
        #expect(WindowMove.target(at: (400, 400), cells: cells, moving: 1) == 0)
    }

    @Test("A window dropped on its own cell, the rail or an empty part stays")
    func aDropThatChangesNothing() {
        #expect(WindowMove.target(at: (400, 400), cells: cells, moving: 0) == nil)
        #expect(WindowMove.target(at: (36, 400), cells: cells, moving: 0) == nil)
        // Under the first tile, where the band is empty.
        #expect(WindowMove.target(at: (1100, 600), cells: cells, moving: 0) == nil)
    }

    @Test("Full has no other cell")
    func fullHasNoOtherPlace() {
        #expect(!WindowMove.isPossible(in: .full))
        #expect(WindowMove.isPossible(in: .principal))
        #expect(WindowMove.isPossible(in: .sideBySide))
        #expect(WindowMove.isPossible(in: .grid))
    }
}

@Suite("The keys")
struct KeyboardFocusRuleTests {
    @Test("The large cell and the keys go together; cells of one rank do not")
    func whoGetsTheKeys() {
        #expect(WindowLayoutKind.principal.keysFollowFirstPlace)
        #expect(WindowLayoutKind.full.keysFollowFirstPlace)
        #expect(!WindowLayoutKind.sideBySide.keysFollowFirstPlace)
        #expect(!WindowLayoutKind.grid.keysFollowFirstPlace)
    }
}
