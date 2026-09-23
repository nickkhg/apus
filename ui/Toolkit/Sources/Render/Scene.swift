// The screen is drawn from a display list: a flat, back-to-front list of
// drawing items. Window contents, the cursor and the shell's own UI all
// become items. The renderer is the only code that writes pixels, so a GPU
// renderer can replace SoftwareRenderer and nothing above it changes.
//
// This module is the bottom of the UI stack. The Toolkit module makes
// display lists from views, and the Compositor module composites windows.

/// A rectangle in screen pixels.
public struct Rect: Sendable, Hashable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
    }
}

/// An image in memory: 32-bit pixels, 0xAARRGGBB, alpha premultiplied.
/// If `isOpaque`, the alpha byte is ignored.
public final class Bitmap {
    public let width: Int
    public let height: Int
    public let isOpaque: Bool
    public var pixels: [UInt32]

    public init(width: Int, height: Int, isOpaque: Bool, pixels: [UInt32]) {
        precondition(pixels.count == width * height)
        (self.width, self.height, self.isOpaque, self.pixels) = (width, height, isOpaque, pixels)
    }

    // MARK: - Pixels that change in place

    /// How many times the pixels changed in place. A window keeps one bitmap
    /// while its size stays, and copies into it only what the app damaged.
    /// The screen then draws only that part again, and the GPU uploads only
    /// that part. See DamageTracker.
    public private(set) var generation = 0
    /// What each change touched, in the bitmap's own pixels.
    private var log: [(generation: Int, rect: Rect)] = []
    /// `changes(since:)` can answer for this generation and every later one.
    private var logStart = 0
    /// Changes kept. A screen asks about the last few frames only.
    private static let logLength = 32

    /// Says that the pixels inside `rects` changed. Call it after the change.
    public func markChanged(_ rects: [Rect]) {
        generation += 1
        let whole = Rect(x: 0, y: 0, width: width, height: height)
        for rect in rects {
            let part = SoftwareRenderer.intersection(rect, whole)
            if part.width > 0, part.height > 0 { log.append((generation, part)) }
        }
        if log.count > Bitmap.logLength {
            let dropped = log.count - Bitmap.logLength
            logStart = log[dropped - 1].generation
            log.removeFirst(dropped)
        }
    }

    /// The parts that changed after `generation`. Nil when the bitmap no
    /// longer knows, and then all of it may have changed.
    public func changes(since generation: Int) -> [Rect]? {
        guard generation >= logStart, generation <= self.generation else { return nil }
        return log.filter { $0.generation > generation }.map(\.rect)
    }
}

/// How much of each pixel a filled path covers: 0 is none, 255 is all.
/// `x` and `y` are where the mask sits on screen.
///
/// A GPU renderer puts this in a texture and colours it there. The CPU
/// renderer needs no mask, because it blends each row as it makes it.
public struct Mask {
    public let x: Int, y: Int, width: Int, height: Int
    /// `width` × `height` values, row by row.
    public let coverage: [UInt8]

    public init(x: Int, y: Int, width: Int, height: Int, coverage: [UInt8]) {
        precondition(coverage.count == width * height)
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
        self.coverage = coverage
    }
}

public enum DisplayItem {
    /// A rectangle of one colour, 0xAARRGGBB with the colour multiplied by
    /// alpha. An alpha of 255 writes the pixels; a smaller alpha blends.
    case fill(Rect, color: UInt32)
    /// A bitmap with its top-left corner at (x, y).
    case bitmap(Bitmap, x: Int, y: Int)
    /// An outline filled with a colour, 0xAARRGGBB with the colour
    /// multiplied by alpha. The edges are smooth.
    case path(Path, color: UInt32)
    /// A soft dark shape under an outline: what a surface that stands off
    /// the background casts. See `Shadow`.
    case shadow(Path, Shadow)
    /// Makes what is already drawn soft, inside an outline. The pixels come
    /// from the picture under the item, so the order of the list matters:
    /// only the items before it are in the blur.
    case blur(Path, radius: Double)
    /// An outline filled with a colour that changes along a line.
    case gradient(Path, Gradient)
    /// Cuts every item after this one to `Rect`, until the `popClip` that
    /// goes with it. Clips inside clips give the common part of the two.
    case pushClip(Rect)
    /// Ends the last `pushClip`.
    case popClip
}

public typealias DisplayList = [DisplayItem]

/// Where the renderer draws: 32-bit XRGB pixels, `stride` pixels per row.
public struct Canvas {
    public let pixels: UnsafeMutablePointer<UInt32>
    public let width: Int
    public let height: Int
    public let stride: Int

    public init(pixels: UnsafeMutablePointer<UInt32>, width: Int, height: Int, stride: Int) {
        (self.pixels, self.width, self.height, self.stride) = (pixels, width, height, stride)
    }
}

/// Draws display lists with the CPU.
public enum SoftwareRenderer {
    public static func render(_ list: DisplayList, into canvas: Canvas) {
        render(list, into: canvas,
               within: Rect(x: 0, y: 0, width: canvas.width, height: canvas.height))
    }

    /// Draws only the pixels inside `region`, and leaves every other pixel
    /// as it was. The canvas must hold the last picture there, and then the
    /// result is the same as drawing the whole list.
    ///
    /// Each rectangle is a clip under every clip of the list. The shape of
    /// an item does not depend on the clip, only which of its pixels are
    /// written, so a pixel comes out the same in part as in whole. A blur
    /// reads the pixels around it; `Region.grown(for:)` makes sure that all
    /// of them are inside the rectangle it is drawn in.
    public static func render(_ list: DisplayList, into canvas: Canvas, region: Region) {
        for rect in region.rects { render(list, into: canvas, within: rect) }
    }

    static func render(_ list: DisplayList, into canvas: Canvas, within bounds: Rect) {
        let whole = intersection(bounds, Rect(x: 0, y: 0, width: canvas.width, height: canvas.height))
        guard whole.width > 0, whole.height > 0 else { return }
        // Every item is cut to `clip`. A pushClip keeps the clip that it
        // replaces, so that the popClip can put it back.
        var clip = whole
        var stack: [Rect] = []
        for item in list {
            switch item {
            case .fill(let rect, let color):
                fill(intersection(rect, clip), color: color, canvas)
            case .bitmap(let bitmap, let x, let y):
                draw(bitmap, x: x, y: y, clip: clip, canvas)
            case .path(let path, let color):
                fill(path, color: color, clip: clip, canvas)
            case .shadow(let path, let shadow):
                draw(shadow, of: path, clip: clip, canvas)
            case .blur(let path, let radius):
                blur(under: path, radius: radius, clip: clip, canvas)
            case .gradient(let path, let gradient):
                fill(path, gradient: gradient, clip: clip, canvas)
            case .pushClip(let rect):
                stack.append(clip)
                clip = intersection(clip, rect)
            case .popClip:
                clip = stack.popLast() ?? whole
            }
        }
    }

    /// The part that two rectangles have in common. An empty result has a
    /// width or a height of zero, and every drawing function skips it.
    static func intersection(_ a: Rect, _ b: Rect) -> Rect {
        let x0 = max(a.x, b.x), y0 = max(a.y, b.y)
        let x1 = min(a.x + a.width, b.x + b.width)
        let y1 = min(a.y + a.height, b.y + b.height)
        return Rect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    private static func fill(_ rect: Rect, color: UInt32, _ canvas: Canvas) {
        let x0 = max(0, rect.x), x1 = min(canvas.width, rect.x + rect.width)
        let y0 = max(0, rect.y), y1 = min(canvas.height, rect.y + rect.height)
        guard x0 < x1, y0 < y1 else { return }
        let alpha = color >> 24
        guard alpha != 0 else { return }
        for row in y0..<y1 {
            let line = UnsafeMutableBufferPointer(
                start: canvas.pixels + row * canvas.stride + x0, count: x1 - x0)
            if alpha == 0xFF {
                line.update(repeating: color)
            } else {
                for index in line.indices { line[index] = blend(color, over: line[index]) }
            }
        }
    }

    private static func draw(_ bitmap: Bitmap, x: Int, y: Int, clip: Rect, _ canvas: Canvas) {
        // Visible part, in bitmap coordinates. The clip is in canvas
        // coordinates, so it moves by the corner of the bitmap.
        let box = intersection(clip, Rect(x: 0, y: 0, width: canvas.width, height: canvas.height))
        let left = max(box.x - x, 0), right = min(bitmap.width, box.x + box.width - x)
        let top = max(box.y - y, 0), bottom = min(bitmap.height, box.y + box.height - y)
        guard left < right, top < bottom else { return }
        let count = right - left

        bitmap.pixels.withUnsafeBufferPointer { source in
            for row in top..<bottom {
                let src = source.baseAddress! + row * bitmap.width + left
                let dst = canvas.pixels + (y + row) * canvas.stride + x + left
                if bitmap.isOpaque {
                    dst.update(from: src, count: count)
                } else {
                    for i in 0..<count { dst[i] = blend(src[i], over: dst[i]) }
                }
            }
        }
    }

    // MARK: - Paths

    private static func fill(_ path: Path, color: UInt32, clip: Rect, _ canvas: Canvas) {
        let box = intersection(clip, Rect(x: 0, y: 0, width: canvas.width, height: canvas.height))
        guard box.width > 0, box.height > 0 else { return }
        rasterize(path, clippedTo: box) { row, left, coverage, width in
            write(coverage, width: width, color: color, row: row, left: left, canvas)
        }
    }

    /// The pixels that a filled path can touch, inside `clip`. Nil when the
    /// path touches none of them.
    public static func bounds(of path: Path, clippedTo clip: Rect) -> Rect? {
        let segments = path.segments().filter { $0.y0 != $0.y1 }
        guard !segments.isEmpty else { return nil }

        var minimum = (x: segments[0].x0, y: segments[0].y0)
        var maximum = minimum
        for segment in segments {
            minimum = (min(minimum.x, segment.x0, segment.x1), min(minimum.y, segment.y0, segment.y1))
            maximum = (max(maximum.x, segment.x0, segment.x1), max(maximum.y, segment.y0, segment.y1))
        }
        let top = max(clip.y, Int(minimum.y.rounded(.down)))
        let bottom = min(clip.y + clip.height, Int(maximum.y.rounded(.up)) + 1)
        let left = max(clip.x, Int(minimum.x.rounded(.down)))
        let right = min(clip.x + clip.width, Int(maximum.x.rounded(.up)) + 1)
        guard top < bottom, left < right else { return nil }
        return Rect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The coverage of a filled path, for a GPU texture.
    ///
    /// This is the same rasterizer that the CPU renderer uses, so a shape
    /// has the same smooth edges on the GPU as on the CPU.
    public static func mask(for path: Path, clippedTo clip: Rect) -> Mask? {
        guard let box = bounds(of: path, clippedTo: clip) else { return nil }
        var coverage = [UInt8](repeating: 0, count: box.width * box.height)
        coverage.withUnsafeMutableBufferPointer { output in
            rasterize(path, clippedTo: clip) { row, left, values, width in
                let start = (row - box.y) * box.width + (left - box.x)
                for index in 0..<width {
                    let amount = values[index]
                    guard amount > 0 else { continue }
                    output[start + index] = UInt8((min(amount, 1) * 255).rounded())
                }
            }
        }
        return Mask(x: box.x, y: box.y, width: box.width, height: box.height, coverage: coverage)
    }

    /// Fills a path with the non-zero winding rule and gives the coverage of
    /// each row that it touches. `handle` gets the row, the first pixel, the
    /// coverage from 0 to 1 for each pixel, and how many pixels there are.
    ///
    /// Each pixel row is sampled on 4 lines, and the ends of a span add a
    /// part of a pixel, so the edges are smooth.
    ///
    /// The coverage of a row is in memory that this function owns, not in an
    /// array: an array checks its bounds and its owner for each pixel, and
    /// that is most of the work in the inner loop.
    static func rasterize(_ path: Path, clippedTo clip: Rect,
                          row handle: (_ row: Int, _ left: Int,
                                       _ coverage: UnsafeMutablePointer<Double>,
                                       _ width: Int) -> Void) {
        let segments = path.segments().filter { $0.y0 != $0.y1 }
        guard !segments.isEmpty, let box = bounds(of: path, clippedTo: clip) else { return }
        let (top, bottom) = (box.y, box.y + box.height)
        let left = box.x

        let samples = 4
        let share = 1.0 / Double(samples)
        let width = box.width
        let coverage = UnsafeMutablePointer<Double>.allocate(capacity: width)
        defer { coverage.deallocate() }
        // The crossings of one sample line. There are never more of them
        // than there are edges, so the memory is allocated one time.
        let crossings = UnsafeMutablePointer<Crossing>.allocate(capacity: segments.count)
        defer { crossings.deallocate() }

        segments.withUnsafeBufferPointer { segments in
            for row in top..<bottom {
                coverage.update(repeating: 0, count: width)
                for sample in 0..<samples {
                    let y = Double(row) + (Double(sample) + 0.5) * share
                    var count = 0
                    for segment in segments {
                        let rising = segment.y1 > segment.y0
                        let low = rising ? segment.y0 : segment.y1
                        let high = rising ? segment.y1 : segment.y0
                        guard y >= low, y < high else { continue }
                        let t = (y - segment.y0) / (segment.y1 - segment.y0)
                        crossings[count] = Crossing(x: segment.x0 + t * (segment.x1 - segment.x0),
                                                    direction: rising ? 1 : -1)
                        count += 1
                    }
                    guard count > 1 else { continue }
                    sort(crossings, count: count)
                    var winding = 0
                    for index in 0..<(count - 1) {
                        winding += crossings[index].direction
                        guard winding != 0 else { continue }
                        add(from: crossings[index].x, to: crossings[index + 1].x,
                            share: share, left: left, width: width, into: coverage)
                    }
                }
                handle(row, left, coverage, width)
            }
        }
    }

    /// Where a sample line crosses an edge, and whether the edge goes down.
    private struct Crossing {
        let x: Double
        let direction: Int
    }

    /// Puts the crossings in order from left to right. A sample line crosses
    /// a shape two or four times, so a simple sort is the fastest one.
    @inline(__always)
    private static func sort(_ crossings: UnsafeMutablePointer<Crossing>, count: Int) {
        for index in 1..<count {
            let crossing = crossings[index]
            var position = index - 1
            while position >= 0, crossings[position].x > crossing.x {
                crossings[position + 1] = crossings[position]
                position -= 1
            }
            crossings[position + 1] = crossing
        }
    }

    /// Adds the coverage of one span of one sample line. A pixel at the end
    /// of the span gets the part of it that the span covers.
    @inline(__always)
    private static func add(from start: Double, to end: Double, share: Double,
                            left: Int, width: Int, into coverage: UnsafeMutablePointer<Double>) {
        let first = max(start, Double(left))
        let last = min(end, Double(left + width))
        guard first < last else { return }

        let firstPixel = Int(first.rounded(.down))
        let lastPixel = Int((last - 1e-9).rounded(.down))
        if firstPixel == lastPixel {
            coverage[firstPixel - left] += (last - first) * share
            return
        }
        // The first and the last pixel get a part. Every pixel between them
        // is completely inside the span.
        coverage[firstPixel - left] += (Double(firstPixel + 1) - first) * share
        if firstPixel + 1 < lastPixel {
            for pixel in (firstPixel + 1)..<lastPixel { coverage[pixel - left] += share }
        }
        coverage[lastPixel - left] += (last - Double(lastPixel)) * share
    }

    private static func write(_ coverage: UnsafeMutablePointer<Double>, width: Int,
                              color: UInt32, row: Int, left: Int, _ canvas: Canvas) {
        let line = canvas.pixels + row * canvas.stride + left
        for index in 0..<width {
            let amount = coverage[index]
            guard amount > 0.002 else { continue }
            line[index] = blend(scale(color, by: min(amount, 1)), over: line[index])
        }
    }

    /// Multiplies a premultiplied colour by a part, for partial coverage.
    @inline(__always)
    static func scale(_ color: UInt32, by part: Double) -> UInt32 {
        guard part < 1 else { return color }
        let amount = UInt32((part * 255).rounded())
        let rb = (((color & 0x00FF00FF) * amount) >> 8) & 0x00FF00FF
        let ag = ((((color >> 8) & 0x00FF00FF) * amount) >> 8) << 8 & 0xFF00FF00
        return rb | ag
    }

    /// Source-over for premultiplied alpha: out = src + dst × (1 − αsrc).
    @inline(__always)
    static func blend(_ src: UInt32, over dst: UInt32) -> UInt32 {
        let alpha = src >> 24
        if alpha == 0xFF { return src }
        if alpha == 0 { return dst }
        let inverse = 255 - alpha
        // Red and blue together, then green, 8 bits of headroom each.
        //
        // The brackets around the multiply matter: Swift shifts before it
        // multiplies, so `a * b >> 8` is `a * (b >> 8)`, which is a * 0 for
        // every inverse below 256.
        let rb = (((dst & 0xFF00FF) * inverse) >> 8) & 0xFF00FF
        let g = (((dst & 0x00FF00) * inverse) >> 8) & 0x00FF00
        return (src & 0xFFFFFF) &+ rb &+ g
    }
}
