// A path is an outline: lines and curves. A shape makes one, and the
// renderer fills it. The renderer is the only code that writes pixels, so a
// GPU renderer can fill the same paths later.

/// An outline of lines and curves, in screen points.
public struct Path: Equatable, Sendable {
    public enum Element: Equatable, Sendable {
        case move(x: Double, y: Double)
        case line(x: Double, y: Double)
        /// A curve with one control point.
        case quadratic(cx: Double, cy: Double, x: Double, y: Double)
        /// A curve with two control points.
        case cubic(c1x: Double, c1y: Double, c2x: Double, c2y: Double, x: Double, y: Double)
        /// A line back to the start of the part.
        case close
    }

    public private(set) var elements: [Element] = []

    public init() {}

    public init(elements: [Element]) {
        self.elements = elements
    }

    public var isEmpty: Bool { elements.isEmpty }

    public mutating func move(to x: Double, _ y: Double) {
        elements.append(.move(x: x, y: y))
    }

    public mutating func line(to x: Double, _ y: Double) {
        elements.append(.line(x: x, y: y))
    }

    public mutating func quadratic(control cx: Double, _ cy: Double, to x: Double, _ y: Double) {
        elements.append(.quadratic(cx: cx, cy: cy, x: x, y: y))
    }

    public mutating func cubic(control1 c1x: Double, _ c1y: Double,
                               control2 c2x: Double, _ c2y: Double,
                               to x: Double, _ y: Double) {
        elements.append(.cubic(c1x: c1x, c1y: c1y, c2x: c2x, c2y: c2y, x: x, y: y))
    }

    public mutating func close() {
        elements.append(.close)
    }

    // MARK: Shapes

    public mutating func addRectangle(x: Double, y: Double, width: Double, height: Double) {
        move(to: x, y)
        line(to: x + width, y)
        line(to: x + width, y + height)
        line(to: x, y + height)
        close()
    }

    /// A rectangle with round corners. The radius is at most half of the
    /// shorter side.
    public mutating func addRoundedRectangle(x: Double, y: Double, width: Double, height: Double,
                                             radius: Double) {
        let r = min(radius, min(width, height) / 2)
        guard r > 0 else { return addRectangle(x: x, y: y, width: width, height: height) }
        // A circle of radius r, from four curves. This is the usual constant.
        let c = r * 0.5522847498307933
        move(to: x + r, y)
        line(to: x + width - r, y)
        cubic(control1: x + width - r + c, y, control2: x + width, y + r - c, to: x + width, y + r)
        line(to: x + width, y + height - r)
        cubic(control1: x + width, y + height - r + c, control2: x + width - r + c, y + height,
              to: x + width - r, y + height)
        line(to: x + r, y + height)
        cubic(control1: x + r - c, y + height, control2: x, y + height - r + c, to: x, y + height - r)
        line(to: x, y + r)
        cubic(control1: x, y + r - c, control2: x + r - c, y, to: x + r, y)
        close()
    }

    public mutating func addEllipse(x: Double, y: Double, width: Double, height: Double) {
        let (rx, ry) = (width / 2, height / 2)
        guard rx > 0, ry > 0 else { return }
        let (cx, cy) = (x + rx, y + ry)
        let (ox, oy) = (rx * 0.5522847498307933, ry * 0.5522847498307933)
        move(to: cx + rx, cy)
        cubic(control1: cx + rx, cy + oy, control2: cx + ox, cy + ry, to: cx, cy + ry)
        cubic(control1: cx - ox, cy + ry, control2: cx - rx, cy + oy, to: cx - rx, cy)
        cubic(control1: cx - rx, cy - oy, control2: cx - ox, cy - ry, to: cx, cy - ry)
        cubic(control1: cx + ox, cy - ry, control2: cx + rx, cy - oy, to: cx + rx, cy)
        close()
    }

    /// The same outline, with every point multiplied by `scale`. A shape is
    /// made in points and drawn in pixels.
    public func scaled(by scale: Double) -> Path {
        guard scale != 1 else { return self }
        return Path(elements: elements.map { element in
            switch element {
            case .move(let x, let y):
                .move(x: x * scale, y: y * scale)
            case .line(let x, let y):
                .line(x: x * scale, y: y * scale)
            case .quadratic(let cx, let cy, let x, let y):
                .quadratic(cx: cx * scale, cy: cy * scale, x: x * scale, y: y * scale)
            case .cubic(let c1x, let c1y, let c2x, let c2y, let x, let y):
                .cubic(c1x: c1x * scale, c1y: c1y * scale, c2x: c2x * scale, c2y: c2y * scale,
                       x: x * scale, y: y * scale)
            case .close:
                .close
            }
        })
    }

    /// Adds the parts of another path to this one.
    public mutating func add(_ other: Path) {
        elements += other.elements
    }

    /// The same outline, drawn the other way round.
    ///
    /// A ring comes from two outlines that go in opposite directions: the
    /// winding of the inner one cancels the winding of the outer one, so the
    /// middle stays empty and only the band between them is filled. This is
    /// how a stroke is drawn.
    public func reversed() -> Path {
        var result = Path()
        var index = 0
        while index < elements.count {
            guard case .move(let startX, let startY) = elements[index] else {
                index += 1
                continue
            }
            // One part: the point it starts at, the segments after it, and
            // whether it closes. Each segment keeps the point it starts from,
            // because that point is where the reversed segment ends.
            var pen = (x: startX, y: startY)
            var segments: [(element: Element, from: (x: Double, y: Double))] = []
            var isClosed = false
            index += 1
            parts: while index < elements.count {
                switch elements[index] {
                case .move:
                    break parts
                case .close:
                    isClosed = true
                    index += 1
                    break parts
                case .line(let x, let y):
                    segments.append((elements[index], pen))
                    pen = (x, y)
                case .quadratic(_, _, let x, let y):
                    segments.append((elements[index], pen))
                    pen = (x, y)
                case .cubic(_, _, _, _, let x, let y):
                    segments.append((elements[index], pen))
                    pen = (x, y)
                }
                index += 1
            }

            result.move(to: pen.x, pen.y)
            for segment in segments.reversed() {
                let end = segment.from
                switch segment.element {
                case .line:
                    result.line(to: end.x, end.y)
                case .quadratic(let cx, let cy, _, _):
                    result.quadratic(control: cx, cy, to: end.x, end.y)
                case .cubic(let c1x, let c1y, let c2x, let c2y, _, _):
                    // The control points swap with the ends.
                    result.cubic(control1: c2x, c2y, control2: c1x, c1y, to: end.x, end.y)
                case .move, .close:
                    break
                }
            }
            if isClosed { result.close() }
        }
        return result
    }

    // MARK: For the renderer

    /// The line segments of the path, with every part closed. A curve becomes
    /// a set of short lines.
    func segments() -> [Segment] {
        var segments: [Segment] = []
        var start = (x: 0.0, y: 0.0)
        var pen = (x: 0.0, y: 0.0)

        func line(to point: (x: Double, y: Double)) {
            if pen != point { segments.append(Segment(x0: pen.x, y0: pen.y, x1: point.x, y1: point.y)) }
            pen = point
        }

        for element in elements {
            switch element {
            case .move(let x, let y):
                // A new part closes the part before it: a fill has no open
                // outlines.
                line(to: start)
                pen = (x, y)
                start = (x, y)
            case .line(let x, let y):
                line(to: (x, y))
            case .quadratic(let cx, let cy, let x, let y):
                let steps = Path.steps(from: pen, through: [(cx, cy)], to: (x, y))
                for step in 1...steps {
                    let t = Double(step) / Double(steps)
                    let u = 1 - t
                    line(to: (u * u * pen.x + 2 * u * t * cx + t * t * x,
                              u * u * pen.y + 2 * u * t * cy + t * t * y))
                }
            case .cubic(let c1x, let c1y, let c2x, let c2y, let x, let y):
                let from = pen
                let steps = Path.steps(from: from, through: [(c1x, c1y), (c2x, c2y)], to: (x, y))
                for step in 1...steps {
                    let t = Double(step) / Double(steps)
                    let u = 1 - t
                    line(to: (u * u * u * from.x + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * x,
                              u * u * u * from.y + 3 * u * u * t * c1y + 3 * u * t * t * c2y + t * t * t * y))
                }
            case .close:
                line(to: start)
            }
        }
        line(to: start)
        return segments
    }

    /// How many lines a curve becomes. A longer curve gets more lines.
    private static func steps(from: (x: Double, y: Double),
                              through controls: [(Double, Double)],
                              to end: (x: Double, y: Double)) -> Int {
        var length = 0.0
        var previous = from
        for control in controls + [end] {
            length += ((control.0 - previous.x) * (control.0 - previous.x)
                       + (control.1 - previous.y) * (control.1 - previous.y)).squareRoot()
            previous = (control.0, control.1)
        }
        return min(max(Int(length / 3), 4), 64)
    }

    struct Segment {
        let x0: Double, y0: Double, x1: Double, y1: Double
    }
}
