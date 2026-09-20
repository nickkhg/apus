// Depth: a shadow, a blur and a gradient.
//
// These three items are what the second mode of the shell draws with. A
// surface stands off the background with a shadow instead of a line, the
// layer under Summon is soft instead of dark, and a gradient replaces a
// step between two flat colours. See docs/toolkit.md.
//
// Every item is in the display list, so both renderers draw them and a view
// asks for depth the same way whatever draws the screen. The CPU is slower
// at all three, and a blur is the slowest: it reads the picture under it,
// makes it soft, and writes it back. That is why the shell asks for them in
// GPU mode only.
//
// The blur is two box passes in each direction. Two boxes give a triangle,
// which is near enough to a Gaussian for an interface and costs the same
// for every radius: a running sum adds one pixel and drops one.

/// A soft dark shape under an outline.
///
/// The shadow is the outline itself, moved by `dx` and `dy` and made soft.
/// A shape with no shadow has a radius of 0 and a colour with no alpha.
public struct Shadow: Sendable, Hashable {
    /// 0xAARRGGBB, with the colour multiplied by alpha, where the shadow is
    /// darkest.
    public var color: UInt32
    /// How far the edge fades, in pixels.
    public var radius: Double
    /// Where the shadow is, from the shape that casts it.
    public var dx: Double
    public var dy: Double

    public init(color: UInt32, radius: Double, dx: Double = 0, dy: Double = 0) {
        self.color = color
        self.radius = radius
        self.dx = dx
        self.dy = dy
    }
}

/// A colour that changes along a line.
///
/// The two colours are 0xAARRGGBB with the colour multiplied by alpha, as
/// every other item wants them. The line is in the same pixels as the path:
/// a pixel on the start point has the first colour, a pixel on the end point
/// has the second, and a pixel outside the two ends has the nearer one.
public struct Gradient: Sendable, Hashable {
    public var from: UInt32
    public var to: UInt32
    public var startX: Double
    public var startY: Double
    public var endX: Double
    public var endY: Double

    public init(from: UInt32, to: UInt32,
                startX: Double, startY: Double, endX: Double, endY: Double) {
        self.from = from
        self.to = to
        self.startX = startX
        self.startY = startY
        self.endX = endX
        self.endY = endY
    }
}

extension SoftwareRenderer {

    // MARK: - How far a blur reaches

    /// The half width of one box pass, for a blur of this radius.
    public static func boxHalfWidth(_ radius: Double) -> Int {
        guard radius > 0 else { return 0 }
        return max(1, Int((radius / 2).rounded()))
    }

    /// How far a blur of this radius moves a pixel, in pixels. A shadow is
    /// this much larger than the shape that casts it, and a blur reads this
    /// much of the picture outside the shape.
    public static func spread(of radius: Double) -> Int {
        2 * boxHalfWidth(radius)
    }

    // MARK: - A shadow

    /// The coverage of a shadow: the shape, moved and made soft.
    ///
    /// The GPU renderer puts this in a texture and colours it there, as it
    /// does with the coverage of a path. A shadow under a cell changes no
    /// more often than the cell does, so the texture is made one time.
    ///
    /// `clip` is the part of the screen that the shadow can reach. A shape
    /// outside it still casts into it, so the shape is looked for in a
    /// larger box.
    public static func shadowMask(for path: Path, _ shadow: Shadow,
                                  clippedTo clip: Rect) -> Mask? {
        let moved = path.translated(dx: shadow.dx, dy: shadow.dy)
        let half = boxHalfWidth(shadow.radius)
        let spread = 2 * half
        let reach = Rect(x: clip.x - spread, y: clip.y - spread,
                         width: clip.width + 2 * spread, height: clip.height + 2 * spread)
        guard let tight = bounds(of: moved, clippedTo: reach) else { return nil }
        // The soft edge goes outside the shape, so the box is larger.
        let box = Rect(x: tight.x - spread, y: tight.y - spread,
                       width: tight.width + 2 * spread, height: tight.height + 2 * spread)

        var coverage = [UInt8](repeating: 0, count: box.width * box.height)
        coverage.withUnsafeMutableBufferPointer { output in
            rasterize(moved, clippedTo: box) { row, left, values, width in
                let start = (row - box.y) * box.width + (left - box.x)
                for index in 0..<width {
                    let amount = values[index]
                    guard amount > 0 else { continue }
                    output[start + index] = UInt8((min(amount, 1) * 255).rounded())
                }
            }
        }
        if half > 0 {
            coverage = blurred(coverage, width: box.width, height: box.height, halfWidth: half)
        }
        return Mask(x: box.x, y: box.y, width: box.width, height: box.height, coverage: coverage)
    }

    static func draw(_ shadow: Shadow, of path: Path, clip: Rect, _ canvas: Canvas) {
        let screen = Rect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let box = intersection(clip, screen)
        guard box.width > 0, box.height > 0, shadow.color >> 24 != 0 else { return }
        guard let mask = shadowMask(for: path, shadow, clippedTo: box) else { return }

        let left = max(box.x, mask.x), right = min(box.x + box.width, mask.x + mask.width)
        let top = max(box.y, mask.y), bottom = min(box.y + box.height, mask.y + mask.height)
        guard left < right, top < bottom else { return }

        mask.coverage.withUnsafeBufferPointer { coverage in
            for row in top..<bottom {
                let line = canvas.pixels + row * canvas.stride
                let start = (row - mask.y) * mask.width - mask.x
                for column in left..<right {
                    let amount = coverage[start + column]
                    guard amount > 0 else { continue }
                    line[column] = blend(scale(shadow.color, by: Double(amount) / 255),
                                         over: line[column])
                }
            }
        }
    }

    // MARK: - A blur

    /// Makes the picture under `path` soft, inside the path.
    ///
    /// The pixels come from the canvas, so everything that the list drew
    /// before this item is in the blur and nothing after it is.
    static func blur(under path: Path, radius: Double, clip: Rect, _ canvas: Canvas) {
        let screen = Rect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let box = intersection(clip, screen)
        let half = boxHalfWidth(radius)
        guard box.width > 0, box.height > 0, half > 0 else { return }
        guard let target = bounds(of: path, clippedTo: box) else { return }

        // The soft pixels at the edge of the shape come from outside it, so
        // the part that is read is larger than the part that is written.
        let spread = 2 * half
        let source = intersection(Rect(x: target.x - spread, y: target.y - spread,
                                       width: target.width + 2 * spread,
                                       height: target.height + 2 * spread), screen)
        guard source.width > 0, source.height > 0 else { return }

        var pixels = [UInt32](repeating: 0, count: source.width * source.height)
        pixels.withUnsafeMutableBufferPointer { output in
            for row in 0..<source.height {
                let line = canvas.pixels + (source.y + row) * canvas.stride + source.x
                (output.baseAddress! + row * source.width).update(from: line, count: source.width)
            }
        }
        let soft = blurred(pixels, width: source.width, height: source.height, halfWidth: half)

        soft.withUnsafeBufferPointer { soft in
            rasterize(path, clippedTo: target) { row, left, values, width in
                let line = canvas.pixels + row * canvas.stride + left
                let y = row - source.y
                guard y >= 0, y < source.height else { return }
                for index in 0..<width {
                    let amount = values[index]
                    guard amount > 0.002 else { continue }
                    let x = left + index - source.x
                    guard x >= 0, x < source.width else { continue }
                    // The canvas has no alpha, so the soft pixels are opaque.
                    let color = 0xFF00_0000 | (soft[y * source.width + x] & 0x00FF_FFFF)
                    line[index] = blend(scale(color, by: min(amount, 1)), over: line[index])
                }
            }
        }
    }

    // MARK: - A gradient

    static func fill(_ path: Path, gradient: Gradient, clip: Rect, _ canvas: Canvas) {
        let screen = Rect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let box = intersection(clip, screen)
        guard box.width > 0, box.height > 0 else { return }

        let dx = gradient.endX - gradient.startX
        let dy = gradient.endY - gradient.startY
        let square = dx * dx + dy * dy
        rasterize(path, clippedTo: box) { row, left, values, width in
            let line = canvas.pixels + row * canvas.stride + left
            let y = Double(row) + 0.5 - gradient.startY
            for index in 0..<width {
                let amount = values[index]
                guard amount > 0.002 else { continue }
                let x = Double(left + index) + 0.5 - gradient.startX
                // How far along the line the pixel is, from 0 to 1.
                let part = square > 0 ? min(max((x * dx + y * dy) / square, 0), 1) : 0
                let color = mix(gradient.from, gradient.to, part)
                line[index] = blend(scale(color, by: min(amount, 1)), over: line[index])
            }
        }
    }

    /// One premultiplied colour on the way to another. Both are multiplied
    /// by their alpha already, so each byte moves on its own.
    static func mix(_ from: UInt32, _ to: UInt32, _ amount: Double) -> UInt32 {
        guard amount > 0 else { return from }
        guard amount < 1 else { return to }
        var result: UInt32 = 0
        for shift in stride(from: 0, through: 24, by: 8) {
            let start = Double((from >> UInt32(shift)) & 0xFF)
            let end = Double((to >> UInt32(shift)) & 0xFF)
            let value = UInt32((start + (end - start) * amount).rounded())
            result |= value << UInt32(shift)
        }
        return result
    }

    // MARK: - The box passes

    /// Coverage made soft: two box passes in each direction.
    static func blurred(_ values: [UInt8], width: Int, height: Int, halfWidth: Int) -> [UInt8] {
        guard halfWidth > 0, width > 0, height > 0 else { return values }
        var front = values
        var back = [UInt8](repeating: 0, count: values.count)
        for _ in 0..<2 {
            box(&front, into: &back, width: width, height: height,
                halfWidth: halfWidth, alongRows: true)
            box(&back, into: &front, width: width, height: height,
                halfWidth: halfWidth, alongRows: false)
        }
        return front
    }

    /// Pixels made soft. The canvas has no alpha, so only three channels
    /// move and the result is opaque.
    static func blurred(_ pixels: [UInt32], width: Int, height: Int, halfWidth: Int) -> [UInt32] {
        guard halfWidth > 0, width > 0, height > 0 else { return pixels }
        var front = pixels
        var back = [UInt32](repeating: 0, count: pixels.count)
        for _ in 0..<2 {
            box(&front, into: &back, width: width, height: height,
                halfWidth: halfWidth, alongRows: true)
            box(&back, into: &front, width: width, height: height,
                halfWidth: halfWidth, alongRows: false)
        }
        return front
    }

    /// One box pass over coverage, along the rows or down the columns.
    ///
    /// The window keeps its sum from one pixel to the next: it adds the
    /// pixel that comes in and takes the one that goes out. A pixel at the
    /// edge answers for every pixel outside it, so the edge does not fade.
    private static func box(_ source: inout [UInt8], into result: inout [UInt8],
                            width: Int, height: Int, halfWidth: Int, alongRows: Bool) {
        let count = alongRows ? width : height
        let lines = alongRows ? height : width
        let step = alongRows ? 1 : width
        let lineStep = alongRows ? width : 1
        let window = 2 * halfWidth + 1

        source.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { result in
                for line in 0..<lines {
                    let base = line * lineStep
                    func value(_ index: Int) -> Int {
                        Int(source[base + min(max(index, 0), count - 1) * step])
                    }
                    var sum = 0
                    for index in -halfWidth...halfWidth { sum += value(index) }
                    for index in 0..<count {
                        result[base + index * step] = UInt8(sum / window)
                        sum += value(index + halfWidth + 1) - value(index - halfWidth)
                    }
                }
            }
        }
    }

    /// One box pass over pixels. The three channels have a sum each.
    private static func box(_ source: inout [UInt32], into result: inout [UInt32],
                            width: Int, height: Int, halfWidth: Int, alongRows: Bool) {
        let count = alongRows ? width : height
        let lines = alongRows ? height : width
        let step = alongRows ? 1 : width
        let lineStep = alongRows ? width : 1
        let window = 2 * halfWidth + 1

        source.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { result in
                for line in 0..<lines {
                    let base = line * lineStep
                    func value(_ index: Int) -> UInt32 {
                        source[base + min(max(index, 0), count - 1) * step]
                    }
                    var red = 0, green = 0, blue = 0
                    func add(_ pixel: UInt32, _ sign: Int) {
                        red += sign * Int((pixel >> 16) & 0xFF)
                        green += sign * Int((pixel >> 8) & 0xFF)
                        blue += sign * Int(pixel & 0xFF)
                    }
                    for index in -halfWidth...halfWidth { add(value(index), 1) }
                    for index in 0..<count {
                        result[base + index * step] = 0xFF00_0000
                            | (UInt32(red / window) << 16)
                            | (UInt32(green / window) << 8)
                            | UInt32(blue / window)
                        add(value(index + halfWidth + 1), 1)
                        add(value(index - halfWidth), -1)
                    }
                }
            }
        }
    }
}
