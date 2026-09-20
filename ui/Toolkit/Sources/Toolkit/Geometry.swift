import Render

/// A width and a height, in points. One point is one pixel for now.
public struct Size: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public static let zero = Size(width: 0, height: 0)

    public init(width: Double, height: Double) {
        (self.width, self.height) = (width, height)
    }
}

/// A position and a size, in points, with fractional edges.
public struct Frame: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
    }

    public init(origin: (x: Double, y: Double), size: Size) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public var size: Size { Size(width: width, height: height) }

    /// The part that this frame and `other` have in common. An empty result
    /// has a width or a height of zero.
    public func intersection(_ other: Frame) -> Frame {
        let x0 = Swift.max(x, other.x), y0 = Swift.max(y, other.y)
        let x1 = Swift.min(x + width, other.x + other.width)
        let y1 = Swift.min(y + height, other.y + other.height)
        return Frame(x: x0, y: y0, width: Swift.max(0, x1 - x0), height: Swift.max(0, y1 - y0))
    }

    /// The whole pixels that this frame covers. The renderer needs integers.
    public var pixels: Rect { pixels(scale: 1) }

    /// The whole pixels that this frame covers on a screen with `scale`
    /// pixels to the point. The layout works in points, and only the
    /// drawing items are in pixels, so one point is the same size on every
    /// screen.
    public func pixels(scale: Double) -> Rect {
        let left = Int((x * scale).rounded()), top = Int((y * scale).rounded())
        return Rect(x: left, y: top,
                    width: Int(((x + width) * scale).rounded()) - left,
                    height: Int(((y + height) * scale).rounded()) - top)
    }
}

/// The space that a parent offers a child. `nil` means "as you like": the
/// child answers with its ideal size. `.infinity` means "as much as you want".
public struct Proposal: Equatable, Sendable {
    public var width: Double?
    public var height: Double?

    /// No size given. Each view answers with its ideal size.
    public static let unspecified = Proposal(width: nil, height: nil)
    /// The smallest size that the view accepts.
    public static let zero = Proposal(width: 0, height: 0)
    /// The largest size that the view accepts.
    public static let infinity = Proposal(width: .infinity, height: .infinity)

    public init(width: Double?, height: Double?) {
        (self.width, self.height) = (width, height)
    }

    public init(_ size: Size) {
        self.init(width: size.width, height: size.height)
    }

    /// The proposal with one axis replaced.
    public func replacing(_ axis: Axis, with length: Double?) -> Proposal {
        axis == .horizontal
            ? Proposal(width: length, height: height)
            : Proposal(width: width, height: length)
    }

    public func length(_ axis: Axis) -> Double? {
        axis == .horizontal ? width : height
    }
}

/// The direction that a stack puts its children in.
public enum Axis: Sendable {
    case horizontal
    case vertical

    public var other: Axis { self == .horizontal ? .vertical : .horizontal }
}

extension Size {
    public func length(_ axis: Axis) -> Double {
        axis == .horizontal ? width : height
    }

    /// Makes a size from a length along `axis` and a length across it.
    public static func along(_ axis: Axis, _ main: Double, across: Double) -> Size {
        axis == .horizontal
            ? Size(width: main, height: across)
            : Size(width: across, height: main)
    }
}

public enum HorizontalAlignment: Sendable {
    case leading, center, trailing
}

public enum VerticalAlignment: Sendable {
    case top, center, bottom
}

/// Where a smaller view sits in a larger space.
public struct Alignment: Sendable {
    public var horizontal: HorizontalAlignment
    public var vertical: VerticalAlignment

    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment) {
        (self.horizontal, self.vertical) = (horizontal, vertical)
    }

    public static let topLeading = Alignment(horizontal: .leading, vertical: .top)
    public static let top = Alignment(horizontal: .center, vertical: .top)
    public static let topTrailing = Alignment(horizontal: .trailing, vertical: .top)
    public static let leading = Alignment(horizontal: .leading, vertical: .center)
    public static let center = Alignment(horizontal: .center, vertical: .center)
    public static let trailing = Alignment(horizontal: .trailing, vertical: .center)
    public static let bottomLeading = Alignment(horizontal: .leading, vertical: .bottom)
    public static let bottom = Alignment(horizontal: .center, vertical: .bottom)
    public static let bottomTrailing = Alignment(horizontal: .trailing, vertical: .bottom)

    /// Puts `size` in `space` and gives the offset from the corner of `space`.
    func offset(for size: Size, in space: Size) -> (x: Double, y: Double) {
        let x: Double = switch horizontal {
        case .leading: 0
        case .center: (space.width - size.width) / 2
        case .trailing: space.width - size.width
        }
        let y: Double = switch vertical {
        case .top: 0
        case .center: (space.height - size.height) / 2
        case .bottom: space.height - size.height
        }
        return (x, y)
    }
}

/// Space to add on the four sides of a view.
public struct EdgeInsets: Equatable, Sendable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(top: Double, leading: Double, bottom: Double, trailing: Double) {
        (self.top, self.leading, self.bottom, self.trailing) = (top, leading, bottom, trailing)
    }

    public init(all length: Double) {
        self.init(top: length, leading: length, bottom: length, trailing: length)
    }

    public var horizontal: Double { leading + trailing }
    public var vertical: Double { top + bottom }
}

/// The sides that a padding modifier adds space to.
public struct Edge: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let top = Edge(rawValue: 1 << 0)
    public static let leading = Edge(rawValue: 1 << 1)
    public static let bottom = Edge(rawValue: 1 << 2)
    public static let trailing = Edge(rawValue: 1 << 3)
    public static let horizontal: Edge = [.leading, .trailing]
    public static let vertical: Edge = [.top, .bottom]
    public static let all: Edge = [.top, .leading, .bottom, .trailing]

    func insets(_ length: Double) -> EdgeInsets {
        EdgeInsets(top: contains(.top) ? length : 0,
                   leading: contains(.leading) ? length : 0,
                   bottom: contains(.bottom) ? length : 0,
                   trailing: contains(.trailing) ? length : 0)
    }
}
