import Render
import Testing

// Damage: a frame draws only the part of the screen that changed.
//
// The rule these tests hold is the only one that matters: a frame drawn in
// part, over the picture of the frame before, is the same picture, pixel for
// pixel, as the frame drawn whole.

private let width = 96
private let height = 64
private let screen = Rect(x: 0, y: 0, width: width, height: height)
private var background: DisplayItem { .fill(screen, color: 0xFF10_1820) }

/// A canvas that keeps its pixels between frames, as a screen buffer does.
private final class Picture {
    var pixels: [UInt32]
    init() { pixels = [UInt32](repeating: 0xFFFF_00FF, count: width * height) }

    func draw(_ list: DisplayList) {
        pixels.withUnsafeMutableBufferPointer { buffer in
            SoftwareRenderer.render(list, into: canvas(buffer))
        }
    }

    func draw(_ list: DisplayList, region: Region) {
        pixels.withUnsafeMutableBufferPointer { buffer in
            SoftwareRenderer.render(list, into: canvas(buffer), region: region)
        }
    }

    private func canvas(_ buffer: UnsafeMutableBufferPointer<UInt32>) -> Canvas {
        Canvas(pixels: buffer.baseAddress!, width: width, height: height, stride: width)
    }
}

private func whole(_ list: DisplayList) -> [UInt32] {
    let picture = Picture()
    picture.draw(list)
    return picture.pixels
}

/// Draws `first` whole, then `second` in part, and gives the damage and
/// whether the result is the same as `second` drawn whole.
@discardableResult
private func expectSame(from first: DisplayList, to second: DisplayList,
                        sourceLocation: SourceLocation = #_sourceLocation) -> Region {
    let tracker = DamageTracker()
    _ = tracker.damage(for: first, screen: screen)
    let picture = Picture()
    picture.draw(first)
    let region = tracker.damage(for: second, screen: screen)
    picture.draw(second, region: region)
    let expected = whole(second)
    let wrong = zip(picture.pixels, expected).enumerated().filter { $0.element.0 != $0.element.1 }
    #expect(wrong.isEmpty,
            "\(wrong.count) pixels differ, the first at \(wrong.first.map { ($0.offset % width, $0.offset / width) }.map { "\($0)" } ?? "")",
            sourceLocation: sourceLocation)
    return region
}

private func square(_ x: Double, _ y: Double, _ side: Double = 16) -> Path {
    var path = Path()
    path.addRectangle(x: x, y: y, width: side, height: side)
    return path
}

private func rounded(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path {
    var path = Path()
    path.addRoundedRectangle(x: x, y: y, width: w, height: h, radius: 6)
    return path
}

private func bitmap(_ w: Int, _ h: Int, _ color: UInt32, opaque: Bool = true) -> Bitmap {
    Bitmap(width: w, height: h, isOpaque: opaque, pixels: [UInt32](repeating: color, count: w * h))
}

@Suite("What a frame changed")
struct DamageTests {
    @Test("The first frame changes the whole screen")
    func firstFrame() {
        let tracker = DamageTracker()
        #expect(tracker.damage(for: [background], screen: screen).rects == [screen])
    }

    @Test("The same list changes nothing")
    func sameList() {
        let list: DisplayList = [background, .path(rounded(10, 10, 30, 20), color: 0xFF80_4020),
                                 .fill(Rect(x: 50, y: 5, width: 10, height: 10), color: 0x8040_2010)]
        let region = expectSame(from: list, to: list)
        #expect(region.isEmpty)
    }

    @Test("A colour that changed damages its item and nothing else")
    func colour() {
        let first: DisplayList = [background,
                                  .fill(Rect(x: 4, y: 4, width: 10, height: 10), color: 0xFF20_2020),
                                  .fill(Rect(x: 60, y: 30, width: 10, height: 10), color: 0xFF30_3030)]
        var second = first
        second[2] = .fill(Rect(x: 60, y: 30, width: 10, height: 10), color: 0xFF90_9090)
        let region = expectSame(from: first, to: second)
        #expect(region.rects == [Rect(x: 60, y: 30, width: 10, height: 10)])
    }

    @Test("An item that goes in damages its own pixels only")
    func insertion() {
        let first: DisplayList = [background,
                                  .fill(Rect(x: 4, y: 4, width: 10, height: 10), color: 0xFF20_2020),
                                  .fill(Rect(x: 60, y: 30, width: 10, height: 10), color: 0xFF30_3030)]
        var second = first
        second.insert(.fill(Rect(x: 30, y: 40, width: 6, height: 6), color: 0xFFA0_A0A0), at: 2)
        let region = expectSame(from: first, to: second)
        #expect(region.rects == [Rect(x: 30, y: 40, width: 6, height: 6)])
    }

    @Test("Two items that change places damage where they meet")
    func order() {
        let a: DisplayItem = .path(square(10, 10, 20), color: 0xFFC0_2020)
        let b: DisplayItem = .path(square(20, 20, 20), color: 0x8020_20C0)
        expectSame(from: [background, a, b], to: [background, b, a])
    }

    @Test("A bitmap that moves damages the old place and the new one")
    func move() {
        let image = bitmap(8, 8, 0xFF40_C040)
        let region = expectSame(from: [background, .bitmap(image, x: 2, y: 2)],
                                to: [background, .bitmap(image, x: 50, y: 30)])
        #expect(region.area == 128)
    }

    @Test("A bitmap that changed in place damages the part that changed")
    func inPlace() {
        let image = bitmap(20, 20, 0xFF40_4040)
        let list: DisplayList = [background, .pushClip(Rect(x: 10, y: 10, width: 30, height: 30)),
                                 .bitmap(image, x: 10, y: 10), .popClip]
        let tracker = DamageTracker()
        _ = tracker.damage(for: list, screen: screen)
        let picture = Picture()
        picture.draw(list)

        for y in 3..<6 { for x in 2..<9 { image.pixels[y * 20 + x] = 0xFFFF_FFFF } }
        image.markChanged([Rect(x: 2, y: 3, width: 7, height: 3)])
        let region = tracker.damage(for: list, screen: screen)
        #expect(region.rects == [Rect(x: 12, y: 13, width: 7, height: 3)])
        picture.draw(list, region: region)
        #expect(picture.pixels == whole(list))
    }

    @Test("A bitmap that forgot its changes is damaged whole")
    func forgotten() {
        let image = bitmap(4, 4, 0xFF40_4040)
        let tracker = DamageTracker()
        let list: DisplayList = [background, .bitmap(image, x: 0, y: 0)]
        _ = tracker.damage(for: list, screen: screen)
        for _ in 0..<40 { image.markChanged([Rect(x: 0, y: 0, width: 1, height: 1)]) }
        #expect(tracker.damage(for: list, screen: screen).rects
                == [Rect(x: 0, y: 0, width: 4, height: 4)])
    }

    @Test("A clip that changed damages what it lets through")
    func clip() {
        let item: DisplayItem = .path(rounded(8, 8, 60, 40), color: 0xFF80_8020)
        expectSame(from: [background, .pushClip(Rect(x: 0, y: 0, width: 30, height: 64)), item, .popClip],
                   to: [background, .pushClip(Rect(x: 0, y: 0, width: 50, height: 64)), item, .popClip])
    }

    @Test("A shadow that moves damages its soft edge too")
    func shadow() {
        let shape = rounded(20, 16, 30, 20)
        expectSame(from: [background, .shadow(shape, Shadow(color: 0xA000_0000, radius: 8, dy: 3))],
                   to: [background, .shadow(shape.translated(dx: 12, dy: 4),
                                            Shadow(color: 0xA000_0000, radius: 8, dy: 3))])
    }

    @Test("A gradient that changed damages its shape")
    func gradient() {
        let shape = rounded(10, 10, 50, 30)
        expectSame(
            from: [background, .gradient(shape, Gradient(from: 0xFF20_2020, to: 0xFFA0_A0A0,
                                                         startX: 10, startY: 10, endX: 60, endY: 40))],
            to: [background, .gradient(shape, Gradient(from: 0xFF20_2020, to: 0xFFA0_2020,
                                                       startX: 10, startY: 10, endX: 60, endY: 40))])
    }

    @Test("A change under a blur draws the whole blur again")
    func underBlur() {
        let glass: DisplayItem = .blur(rounded(20, 10, 50, 40), radius: 8)
        let top: DisplayItem = .fill(Rect(x: 30, y: 20, width: 10, height: 10), color: 0x6020_2020)
        let first: DisplayList = [background, .fill(Rect(x: 25, y: 15, width: 8, height: 8),
                                                     color: 0xFFE0_E0E0), glass, top]
        var second = first
        second[1] = .fill(Rect(x: 26, y: 15, width: 8, height: 8), color: 0xFFE0_E0E0)
        let region = expectSame(from: first, to: second)
        #expect(region.rects.count == 1)
    }

    @Test("A change beside a blur, inside what it reads, changes the blur")
    func besideBlur() {
        // The blur reads 8 pixels outside its shape. The square changes
        // there and not under the shape.
        let glass: DisplayItem = .blur(square(30, 20, 20), radius: 8)
        let first: DisplayList = [background, .fill(Rect(x: 24, y: 24, width: 4, height: 4),
                                                     color: 0xFFFF_FFFF), glass]
        var second = first
        second[1] = .fill(Rect(x: 24, y: 24, width: 4, height: 4), color: 0xFF00_00FF)
        expectSame(from: first, to: second)
    }

    @Test("A change far from a blur leaves the blur alone")
    func farFromBlur() {
        let glass: DisplayItem = .blur(square(60, 30, 20), radius: 4)
        let first: DisplayList = [background, .fill(Rect(x: 2, y: 2, width: 6, height: 6),
                                                     color: 0xFFFF_FFFF), glass]
        var second = first
        second[1] = .fill(Rect(x: 2, y: 2, width: 6, height: 6), color: 0xFF00_00FF)
        let region = expectSame(from: first, to: second)
        #expect(region.rects == [Rect(x: 2, y: 2, width: 6, height: 6)])
    }

    @Test("A blur at the edge of the screen is the same in part")
    func blurAtEdge() {
        let glass: DisplayItem = .blur(square(-4, -4, 30), radius: 10)
        let first: DisplayList = [background,
                                  .fill(Rect(x: 0, y: 0, width: 5, height: 40), color: 0xFFFF_2020),
                                  .fill(Rect(x: 10, y: 0, width: 3, height: 3), color: 0xFF20_FF20),
                                  glass]
        var second = first
        second[2] = .fill(Rect(x: 11, y: 0, width: 3, height: 3), color: 0xFF20_FF20)
        expectSame(from: first, to: second)
    }

    @Test("Random edits are drawn the same in part as in whole")
    func random() {
        var generator = Numbers(seed: 7)
        let images = [bitmap(9, 7, 0xFF30_A0D0), bitmap(5, 12, 0x80A0_3010, opaque: false)]
        var partial = 0
        func item() -> DisplayItem {
            let x = Double(generator.next(80)) - 8, y = Double(generator.next(56)) - 8
            let color = 0xFF00_0000 | UInt32(generator.next(0xFFFFFF))
            switch generator.next(8) {
            case 6: return .gradient(rounded(x, y, 20, 14), Gradient(
                from: color, to: 0xFF20_2020, startX: x, startY: y, endX: x + 20, endY: y + 14))
            case 7: return .bitmap(images[generator.next(images.count)], x: Int(x), y: Int(y))
            case 0: return .fill(Rect(x: Int(x), y: Int(y), width: 3 + generator.next(20),
                                      height: 3 + generator.next(20)), color: color)
            case 1: return .path(rounded(x, y, 6 + Double(generator.next(30)),
                                         6 + Double(generator.next(20))), color: color & 0x80FF_FFFF)
            case 2: return .shadow(square(x, y, 12), Shadow(color: 0x9000_0000, radius: 6, dy: 2))
            case 3: return .blur(square(x, y, 18), radius: Double(2 + generator.next(8)))
            case 4: return .pushClip(Rect(x: Int(x), y: Int(y), width: 40, height: 30))
            default: return .popClip
            }
        }
        for _ in 0..<300 {
            var first: DisplayList = [background]
            for _ in 0..<12 { first.append(item()) }
            var second = first
            for _ in 0..<(1 + generator.next(3)) {
                switch generator.next(3) {
                case 0: second.insert(item(), at: 1 + generator.next(second.count))
                case 1 where second.count > 1: second.remove(at: 1 + generator.next(second.count - 1))
                default: second[1 + generator.next(second.count - 1)] = item()
                }
            }
            if expectSame(from: first, to: second).area < width * height { partial += 1 }
        }
        // Most of them must be drawn in part, or the test holds nothing.
        #expect(partial > 150)
    }

    @Test("Two buffers take turns and each is brought up to date")
    func twoBuffers() {
        var history = DamageHistory()
        let tracker = DamageTracker()
        let buffers = [Picture(), Picture()]
        var held = [0, 0]
        var lists: [DisplayList] = []
        var list: DisplayList = [background]
        for step in 0..<12 {
            list.append(.fill(Rect(x: (step * 7) % 80, y: (step * 5) % 50, width: 9, height: 9),
                              color: 0xFF00_0000 | UInt32(step * 0x151515)))
            if step % 4 == 3 { list.remove(at: 1) }
            lists.append(list)
            let frame = history.record(tracker.damage(for: list, screen: screen))
            let back = step % 2
            let region = history.changes(after: held[back], screen: screen).grown(for: list, screen: screen)
            buffers[back].draw(list, region: region)
            held[back] = frame
            #expect(buffers[back].pixels == whole(list), "frame \(frame)")
        }
        #expect(lists.count == 12)
    }

    @Test("A buffer older than the history is drawn whole")
    func tooOld() {
        var history = DamageHistory()
        for _ in 0..<10 { _ = history.record(Region()) }
        #expect(history.changes(after: 9, screen: screen).isEmpty)
        #expect(history.changes(after: 1, screen: screen).rects == [screen])
        #expect(history.changes(after: 0, screen: screen).rects == [screen])
        history.reset()
        #expect(history.changes(after: 10, screen: screen).rects == [screen])
    }
}

@Suite("A region")
struct RegionTests {
    @Test("Rectangles that overlap become one, and ones that do not stay apart")
    func overlap() {
        var region = Region()
        region.add(Rect(x: 0, y: 0, width: 10, height: 10))
        region.add(Rect(x: 20, y: 0, width: 10, height: 10))
        #expect(region.rects.count == 2)
        region.add(Rect(x: 5, y: 5, width: 20, height: 2))
        #expect(region.rects == [Rect(x: 0, y: 0, width: 30, height: 10)])
    }

    @Test("Rectangles that only touch stay apart")
    func touch() {
        var region = Region()
        region.add(Rect(x: 0, y: 0, width: 10, height: 10))
        region.add(Rect(x: 10, y: 0, width: 10, height: 10))
        #expect(region.rects.count == 2)
    }

    @Test("Too many rectangles become fewer, and none of them overlap")
    func many() {
        var region = Region()
        for index in 0..<40 {
            region.add(Rect(x: (index * 37) % 900, y: (index * 53) % 700, width: 12, height: 9))
        }
        #expect(region.rects.count <= Region.most)
        for (i, a) in region.rects.enumerated() {
            for b in region.rects.dropFirst(i + 1) {
                let x = max(a.x, b.x) < min(a.x + a.width, b.x + b.width)
                let y = max(a.y, b.y) < min(a.y + a.height, b.y + b.height)
                #expect(!(x && y))
            }
        }
    }
}

/// The same numbers on every run.
private struct Numbers {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ below: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(max(below, 1)))
    }
}
