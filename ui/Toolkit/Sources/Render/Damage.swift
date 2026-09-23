// Damage: the part of the screen that a frame changes.
//
// A frame that redraws every pixel costs the size of the screen, whatever
// changed. Most frames change very little: a line of a terminal, the minute
// of the clock, a button that lights up under the pointer. So the screen
// keeps the picture that it drew, finds the part of the new frame that is
// different, and draws that part only.
//
// Two things say what changed:
//
// - The display list. `DamageTracker` compares the list of this frame with
//   the list of the last one. An item that is in both, in the same order,
//   changed nothing. Every other item changed the pixels under it, in the
//   old list and in the new one.
// - The pixels of a bitmap that changed in place. A window keeps one Bitmap
//   and copies what the app damaged into it (wl_surface.damage), so the
//   item is the same and only the damaged part of it counts.
//
// A blur reads the picture around it. A change near a blur changes the blur,
// so the damage grows to cover everything that the blur reads, and a part
// of the damage that touches a blur holds all of it. See `grown(for:)`.

/// A set of rectangles that do not overlap, in screen pixels.
///
/// Each rectangle is drawn on its own, with the rectangle as the clip, so
/// two of them must never share a pixel: that pixel would get every item
/// twice. A rectangle that overlaps another becomes the box around the two.
public struct Region: Sendable, Equatable {
    public private(set) var rects: [Rect] = []

    /// More rectangles than this cost more to walk than they save, so the
    /// two that waste least become one.
    public static let most = 12

    public init() {}

    public init(_ rect: Rect) { add(rect) }

    public var isEmpty: Bool { rects.isEmpty }

    /// The number of pixels in the region.
    public var area: Int { rects.reduce(0) { $0 + $1.width * $1.height } }

    /// The box around every rectangle, or nil for an empty region.
    public var bounds: Rect? {
        guard var box = rects.first else { return nil }
        for rect in rects.dropFirst() { box = Region.box(around: box, rect) }
        return box
    }

    public mutating func add(_ rect: Rect) {
        guard rect.width > 0, rect.height > 0 else { return }
        var rect = rect
        // A rectangle that grows can meet one that it did not meet before,
        // so this goes round until nothing overlaps.
        var merged = true
        while merged {
            merged = false
            for index in rects.indices.reversed() where Region.overlap(rects[index], rect) {
                rect = Region.box(around: rect, rects.remove(at: index))
                merged = true
            }
        }
        rects.append(rect)
        if rects.count > Region.most { mergeCheapestPair() }
    }

    public mutating func add(_ other: Region) {
        for rect in other.rects { add(rect) }
    }

    /// Everything inside `rect` only.
    public func clipped(to rect: Rect) -> Region {
        var result = Region()
        for part in rects { result.add(Region.intersection(part, rect)) }
        return result
    }

    public func intersects(_ rect: Rect) -> Bool {
        rects.contains { Region.overlap($0, rect) }
    }

    /// The two rectangles whose box wastes the fewest pixels become one.
    private mutating func mergeCheapestPair() {
        var best = (first: 0, second: 1, waste: Int.max)
        for first in rects.indices {
            for second in rects.indices where second > first {
                let box = Region.box(around: rects[first], rects[second])
                let waste = box.width * box.height
                    - rects[first].width * rects[first].height
                    - rects[second].width * rects[second].height
                if waste < best.waste { best = (first, second, waste) }
            }
        }
        let box = Region.box(around: rects[best.first], rects[best.second])
        rects.remove(at: best.second)
        rects.remove(at: best.first)
        add(box)
    }

    static func overlap(_ a: Rect, _ b: Rect) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width
            && a.y < b.y + b.height && b.y < a.y + a.height
    }

    static func box(around a: Rect, _ b: Rect) -> Rect {
        let x0 = min(a.x, b.x), y0 = min(a.y, b.y)
        let x1 = max(a.x + a.width, b.x + b.width), y1 = max(a.y + a.height, b.y + b.height)
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func intersection(_ a: Rect, _ b: Rect) -> Rect {
        SoftwareRenderer.intersection(a, b)
    }

    static func contains(_ outer: Rect, _ inner: Rect) -> Bool {
        inner.x >= outer.x && inner.y >= outer.y
            && inner.x + inner.width <= outer.x + outer.width
            && inner.y + inner.height <= outer.y + outer.height
    }

    // MARK: - Blurs

    /// The region, grown so that every blur in `list` is drawn from pixels
    /// of this frame.
    ///
    /// A blur reads the picture under it and around it: the part it writes,
    /// and `spread` pixels more on each side. Those pixels must be the ones
    /// that the items before the blur drew in this frame, and not what the
    /// buffer held from an older one. So a rectangle that touches what a
    /// blur reads grows to hold all of it, and the blur is drawn once, whole,
    /// inside one rectangle.
    ///
    /// This also covers a change that is near a blur and not under it: the
    /// blur mixes that change into the pixels that it writes.
    public func grown(for list: DisplayList, screen: Rect) -> Region {
        let reads = Region.blurReads(in: list, screen: screen)
        guard !reads.isEmpty, !isEmpty else { return self }
        var region = self
        var changed = true
        while changed {
            changed = false
            for read in reads where region.rects.contains(where: {
                Region.overlap($0, read) && !Region.contains($0, read)
            }) {
                region.add(read)
                changed = true
            }
        }
        return region
    }

    /// The part of the screen that each blur of the list reads.
    static func blurReads(in list: DisplayList, screen: Rect) -> [Rect] {
        var reads: [Rect] = []
        var clip = screen
        var stack: [Rect] = []
        for item in list {
            switch item {
            case .pushClip(let rect):
                stack.append(clip)
                clip = intersection(clip, rect)
            case .popClip:
                clip = stack.popLast() ?? screen
            case .blur(let path, let radius):
                let box = intersection(clip, screen)
                guard box.width > 0, box.height > 0,
                      let target = SoftwareRenderer.bounds(of: path, clippedTo: box) else { continue }
                let spread = SoftwareRenderer.spread(of: radius)
                let read = intersection(Rect(x: target.x - spread, y: target.y - spread,
                                             width: target.width + 2 * spread,
                                             height: target.height + 2 * spread), screen)
                if read.width > 0, read.height > 0 { reads.append(read) }
            default:
                continue
            }
        }
        return reads
    }
}

// MARK: - What a frame changed

/// Compares each frame's display list with the one before it, and says
/// which pixels are different.
///
/// An item is the same as an item of the last frame when it draws the same
/// thing in the same clip: the same kind, the same numbers, and for a bitmap
/// the same object. The two lists are matched in order, with the diff of
/// Myers, so an item that went in or out changes its own pixels and not the
/// pixels of every item after it. A pixel that no changed item touches is
/// the same picture as before, because the same items drew it in the same
/// order.
public final class DamageTracker {
    /// One drawing item and the clip it is drawn in. The clip items are
    /// folded into this, so two lists that clip the same way compare equal.
    struct Entry {
        let item: DisplayItem
        let clip: Rect
        /// For a bitmap: how many times its pixels had changed in place.
        let generation: Int
        let hash: Int
    }

    private var previous: [Entry]?
    private var previousScreen: Rect?

    /// Past this many changes, the diff costs more than drawing the whole
    /// part of the screen that the lists cover.
    static let longestEdit = 64

    public init() {}

    /// Forgets the last list. The next frame is new everywhere.
    public func reset() {
        previous = nil
        previousScreen = nil
    }

    /// The pixels that `list` changes from the list of the last call, grown
    /// for the blurs of `list`. The whole screen for the first frame and for
    /// a screen of a new size.
    public func damage(for list: DisplayList, screen: Rect) -> Region {
        let entries = DamageTracker.entries(of: list, screen: screen)
        defer { previous = entries; previousScreen = screen }
        guard let previous, previousScreen == screen else { return Region(screen) }
        return DamageTracker.changes(from: previous, to: entries, screen: screen)
            .grown(for: list, screen: screen)
    }

    static func changes(from old: [Entry], to new: [Entry], screen: Rect) -> Region {
        var region = Region()
        func damage(_ entry: Entry) {
            if let rect = bounds(of: entry, screen: screen) { region.add(rect) }
        }

        // The same items at the start and at the end are common, and the
        // diff needs only the part between them.
        var start = 0
        while start < old.count, start < new.count, same(old[start], new[start]) {
            contentDamage(old[start], new[start], screen: screen, into: &region)
            start += 1
        }
        var oldEnd = old.count, newEnd = new.count
        while oldEnd > start, newEnd > start, same(old[oldEnd - 1], new[newEnd - 1]) {
            contentDamage(old[oldEnd - 1], new[newEnd - 1], screen: screen, into: &region)
            oldEnd -= 1
            newEnd -= 1
        }
        let oldMiddle = old[start..<oldEnd], newMiddle = new[start..<newEnd]
        if oldMiddle.isEmpty || newMiddle.isEmpty {
            oldMiddle.forEach(damage)
            newMiddle.forEach(damage)
            return region
        }

        guard let pairs = matches(Array(oldMiddle), Array(newMiddle)) else {
            // Too different to be worth the diff: every item of the middle
            // changed. That is still right, only larger.
            oldMiddle.forEach(damage)
            newMiddle.forEach(damage)
            return region
        }
        var oldIndex = 0, newIndex = 0
        for pair in pairs + [(oldMiddle.count, newMiddle.count)] {
            while oldIndex < pair.0 { damage(oldMiddle[start + oldIndex]); oldIndex += 1 }
            while newIndex < pair.1 { damage(newMiddle[start + newIndex]); newIndex += 1 }
            guard pair.0 < oldMiddle.count else { break }
            contentDamage(oldMiddle[start + pair.0], newMiddle[start + pair.1],
                          screen: screen, into: &region)
            oldIndex += 1
            newIndex += 1
        }
        return region
    }

    /// A bitmap that is the same object as before, with pixels that changed
    /// in place: the part that changed, where the bitmap is.
    private static func contentDamage(_ old: Entry, _ new: Entry, screen: Rect,
                                      into region: inout Region) {
        guard old.generation != new.generation,
              case .bitmap(let bitmap, let x, let y) = new.item else { return }
        let visible = SoftwareRenderer.intersection(new.clip, screen)
        guard let changes = bitmap.changes(since: old.generation) else {
            if let rect = bounds(of: new, screen: screen) { region.add(rect) }
            return
        }
        for change in changes {
            region.add(SoftwareRenderer.intersection(
                Rect(x: x + change.x, y: y + change.y, width: change.width, height: change.height),
                visible))
        }
    }

    /// The pairs of items that the two lists have in common, in order, as
    /// (index in old, index in new). Nil when the lists differ by more than
    /// `longestEdit` items.
    ///
    /// This is the greedy diff of Myers: for each number of edits `d`, the
    /// furthest point that each diagonal reaches. It costs the length of
    /// the lists times the number of edits, and a frame changes few items.
    static func matches(_ old: [Entry], _ new: [Entry]) -> [(Int, Int)]? {
        let n = old.count, m = new.count
        let most = min(n + m, longestEdit)
        let offset = most + 1
        var furthest = [Int](repeating: 0, count: 2 * most + 3)
        var trace: [[Int]] = []
        var found = false
        search: for d in 0...most {
            trace.append(furthest)
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && furthest[offset + k - 1] < furthest[offset + k + 1]) {
                    x = furthest[offset + k + 1]          // a step down: an insertion
                } else {
                    x = furthest[offset + k - 1] + 1      // a step right: a deletion
                }
                var y = x - k
                while x < n, y < m, same(old[x], new[y]) { x += 1; y += 1 }
                furthest[offset + k] = x
                if x >= n, y >= m { found = true; break search }
            }
        }
        guard found else { return nil }

        // Walk back through the trace and keep the diagonal steps.
        var pairs: [(Int, Int)] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let row = trace[d]
            let k = x - y
            let previousK: Int
            if k == -d || (k != d && row[offset + k - 1] < row[offset + k + 1]) {
                previousK = k + 1
            } else {
                previousK = k - 1
            }
            let previousX = d == 0 ? 0 : row[offset + previousK]
            let previousY = previousX - previousK
            while x > previousX, y > previousY {
                x -= 1; y -= 1
                pairs.append((x, y))
            }
            if d > 0 { x = previousX; y = previousY }
        }
        return pairs.reversed()
    }

    // MARK: - Items

    static func entries(of list: DisplayList, screen: Rect) -> [Entry] {
        var entries: [Entry] = []
        entries.reserveCapacity(list.count)
        var clip = screen
        var stack: [Rect] = []
        for item in list {
            switch item {
            case .pushClip(let rect):
                stack.append(clip)
                clip = SoftwareRenderer.intersection(clip, rect)
            case .popClip:
                clip = stack.popLast() ?? screen
            case .bitmap(let bitmap, _, _):
                entries.append(Entry(item: item, clip: clip, generation: bitmap.generation,
                                     hash: hash(item, clip)))
            default:
                entries.append(Entry(item: item, clip: clip, generation: 0,
                                     hash: hash(item, clip)))
            }
        }
        return entries
    }

    private static func hash(_ item: DisplayItem, _ clip: Rect) -> Int {
        var hasher = Hasher()
        hasher.combine(clip)
        switch item {
        case .fill(let rect, let color):
            hasher.combine(0); hasher.combine(rect); hasher.combine(color)
        case .bitmap(let bitmap, let x, let y):
            hasher.combine(1); hasher.combine(ObjectIdentifier(bitmap))
            hasher.combine(x); hasher.combine(y)
        case .path(let path, let color):
            hasher.combine(2); hasher.combine(path); hasher.combine(color)
        case .shadow(let path, let shadow):
            hasher.combine(3); hasher.combine(path); hasher.combine(shadow)
        case .blur(let path, let radius):
            hasher.combine(4); hasher.combine(path); hasher.combine(radius)
        case .gradient(let path, let gradient):
            hasher.combine(5); hasher.combine(path); hasher.combine(gradient)
        case .pushClip, .popClip:
            hasher.combine(6)
        }
        return hasher.finalize()
    }

    /// Whether two entries draw the same pixels. The pixels of a bitmap
    /// that changed in place are not part of this: `contentDamage` adds
    /// them.
    static func same(_ a: Entry, _ b: Entry) -> Bool {
        guard a.hash == b.hash, a.clip == b.clip else { return false }
        switch (a.item, b.item) {
        case let (.fill(r1, c1), .fill(r2, c2)):
            return r1 == r2 && c1 == c2
        case let (.bitmap(b1, x1, y1), .bitmap(b2, x2, y2)):
            return b1 === b2 && x1 == x2 && y1 == y2
        case let (.path(p1, c1), .path(p2, c2)):
            return c1 == c2 && p1 == p2
        case let (.shadow(p1, s1), .shadow(p2, s2)):
            return s1 == s2 && p1 == p2
        case let (.blur(p1, r1), .blur(p2, r2)):
            return r1 == r2 && p1 == p2
        case let (.gradient(p1, g1), .gradient(p2, g2)):
            return g1 == g2 && p1 == p2
        default:
            return false
        }
    }

    /// Every pixel that an entry can change, in the screen and its clip.
    /// Nil when it changes none.
    static func bounds(of entry: Entry, screen: Rect) -> Rect? {
        let visible = SoftwareRenderer.intersection(entry.clip, screen)
        let reach: Rect?
        switch entry.item {
        case .fill(let rect, _):
            reach = rect
        case .bitmap(let bitmap, let x, let y):
            reach = Rect(x: x, y: y, width: bitmap.width, height: bitmap.height)
        case .path(let path, _), .gradient(let path, _), .blur(let path, _):
            reach = hull(of: path)
        case .shadow(let path, let shadow):
            let spread = SoftwareRenderer.spread(of: shadow.radius)
            reach = hull(of: path.translated(dx: shadow.dx, dy: shadow.dy)).map {
                Rect(x: $0.x - spread, y: $0.y - spread,
                     width: $0.width + 2 * spread, height: $0.height + 2 * spread)
            }
        case .pushClip, .popClip:
            reach = nil
        }
        guard let reach else { return nil }
        let rect = SoftwareRenderer.intersection(reach, visible)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    /// The box around every point of a path, control points too, and one
    /// pixel more on each side. A curve stays inside its control points, and
    /// the GPU draws a rounded rectangle one pixel wider than the shape for
    /// its smooth edge.
    static func hull(of path: Path) -> Rect? {
        var low = (x: Double.infinity, y: Double.infinity)
        var high = (x: -Double.infinity, y: -Double.infinity)
        func take(_ x: Double, _ y: Double) {
            low = (min(low.x, x), min(low.y, y))
            high = (max(high.x, x), max(high.y, y))
        }
        for element in path.elements {
            switch element {
            case .move(let x, let y), .line(let x, let y):
                take(x, y)
            case .quadratic(let cx, let cy, let x, let y):
                take(cx, cy); take(x, y)
            case .cubic(let c1x, let c1y, let c2x, let c2y, let x, let y):
                take(c1x, c1y); take(c2x, c2y); take(x, y)
            case .close:
                break
            }
        }
        guard low.x <= high.x, low.y <= high.y, low.x.isFinite, high.y.isFinite else { return nil }
        let left = Int(low.x.rounded(.down)) - 1, top = Int(low.y.rounded(.down)) - 1
        let right = Int(high.x.rounded(.up)) + 2, bottom = Int(high.y.rounded(.up)) + 2
        return Rect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

// MARK: - The frames a buffer missed

/// What each of the last few frames changed, so that a buffer that holds an
/// older frame can be brought up to date.
///
/// A screen draws into more than one buffer, and the buffer that it draws
/// into next holds the frame of two or three frames ago, not the last one.
/// Its damage is what every frame since then changed.
public struct DamageHistory {
    /// A buffer this far behind is drawn again whole.
    public static let depth = 6

    /// The number of the newest frame. The first frame is 1, and 0 is a
    /// buffer that holds no frame.
    public private(set) var latest = 0
    private var frames: [(number: Int, region: Region)] = []
    /// No buffer that holds a frame older than this can be brought up to
    /// date: a reset came after it.
    private var firstUsable = 1

    public init() {}

    /// Keeps what a new frame changed, and gives the number of that frame.
    public mutating func record(_ region: Region) -> Int {
        latest += 1
        frames.append((latest, region))
        if frames.count > DamageHistory.depth { frames.removeFirst() }
        return latest
    }

    /// Forgets every frame: no buffer holds a picture that can be used. A
    /// new size of the screen does this.
    public mutating func reset() {
        frames.removeAll()
        firstUsable = latest + 1
    }

    /// What changed after frame `held`, up to and with frame `through`.
    /// The whole screen when the history does not reach back that far.
    public func changes(after held: Int, through: Int? = nil, screen: Rect) -> Region {
        let last = through ?? latest
        guard held >= firstUsable, held >= latest - DamageHistory.depth, held <= last else {
            return Region(screen)
        }
        var region = Region()
        for frame in frames where frame.number > held && frame.number <= last {
            region.add(frame.region)
        }
        return region.clipped(to: screen)
    }
}
