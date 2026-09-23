import Render

// A view that is taller than its space, and a wheel that moves it.
//
// The content is laid out at the height that it wants, and the frame shows
// a window of it. The owner of the window gives the wheel to `ViewHost`,
// and the host gives it to the scroll view under the pointer. A scroll view
// that is already at its end does not use the wheel, so the one around it
// gets it instead.
//
//     ScrollView {
//         ForEach(zones) { zone in Row(zone) }
//     }
//
// The content moves along the vertical axis only. Its width is the width of
// the frame.

/// A view that shows a part of a taller view, and moves with the wheel.
public struct ScrollView<Content: View>: View {
    let content: Content
    let binding: Binding<Double>?
    let reveal: ClosedRange<Double>?
    let indicator: Color
    @State private var offset = 0.0

    /// The scroll view keeps how far it is scrolled.
    public init(indicator: Color = Color(white: 1, alpha: 0.16),
                @ViewBuilder content: () -> Content) {
        self.content = content()
        self.binding = nil
        self.reveal = nil
        self.indicator = indicator
    }

    /// The owner keeps how far it is scrolled, in points from the top.
    /// The scroll view keeps the value inside the content.
    ///
    /// `reveal` is a part of the content, in points from its top, that the
    /// view moves the least it can to show: a row that the keyboard just
    /// selected. Give it in the frame after the selection moved, and not in
    /// every frame, or the wheel could never take the row out of sight.
    public init(offset: Binding<Double>, reveal: ClosedRange<Double>? = nil,
                indicator: Color = Color(white: 1, alpha: 0.16),
                @ViewBuilder content: () -> Content) {
        self.content = content()
        self.binding = offset
        self.reveal = reveal
        self.indicator = indicator
    }

    public var body: some View {
        ScrollArea(content: content, offset: binding ?? $offset, reveal: reveal,
                   indicator: indicator)
    }
}

/// The part of a scroll view that lays out and draws.
struct ScrollArea<Content: View>: View {
    typealias Body = Never
    let content: Content
    let offset: Binding<Double>
    let reveal: ClosedRange<Double>?
    let indicator: Color

    func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        nodes.append(ScrollNode(child: content.node(environment: environment),
                                offset: offset, reveal: reveal, indicator: indicator))
    }
}

/// A view that uses the wheel while the pointer is over it.
public struct ScrollRegion {
    /// Where the view is, in points on the screen.
    public internal(set) var frame: Frame
    /// Answers whether the view moved. `delta` is in points, and a positive
    /// one moves the content up, towards its end.
    let handler: (Double) -> Bool

    public func contains(x: Double, y: Double) -> Bool {
        x >= frame.x && x < frame.x + frame.width && y >= frame.y && y < frame.y + frame.height
    }
}

final class ScrollNode: LayoutNode {
    let child: LayoutNode
    let offset: Binding<Double>
    let reveal: ClosedRange<Double>?
    let indicator: Color

    /// The width of the line that says where the view is.
    static let indicatorWidth = 3.0

    init(child: LayoutNode, offset: Binding<Double>, reveal: ClosedRange<Double>?,
         indicator: Color) {
        self.child = child
        self.offset = offset
        self.reveal = reveal
        self.indicator = indicator
    }

    /// The width that the content wants, and all of the height that the
    /// parent offers. A scroll view with no height offered is as tall as
    /// what it holds, and then it has nothing to scroll.
    override func computeSize(fitting proposal: Proposal) -> Size {
        let inner = child.size(fitting: Proposal(width: proposal.width, height: nil))
        let height: Double = if let offered = proposal.height, offered.isFinite {
            offered
        } else {
            inner.height
        }
        return Size(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? inner.width,
                    height: height)
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        let rect = frame.pixels(scale: pass.scale)
        guard rect.width > 0, rect.height > 0 else { return }
        let contentHeight = child.size(fitting: Proposal(width: frame.width, height: nil)).height
        let limit = max(0, contentHeight - frame.height)
        var shown = min(max(0, offset.wrappedValue), limit)
        if let reveal {
            // The least move that shows the part: its bottom at the bottom
            // of the frame, or its top at the top, whichever is nearer.
            if reveal.upperBound > shown + frame.height { shown = reveal.upperBound - frame.height }
            if reveal.lowerBound < shown { shown = reveal.lowerBound }
            shown = min(max(0, shown), limit)
            if shown != offset.wrappedValue { offset.wrappedValue = shown }
        }

        // This region goes before the ones of the content, so that the
        // host, which reads from the last one back, asks a scroll view
        // inside this one first.
        let binding = offset
        pass.scrollRegions.append(ScrollRegion(frame: frame) { delta in
            let now = min(max(0, binding.wrappedValue), limit)
            let next = min(max(0, now + delta), limit)
            guard next != now else { return false }
            binding.wrappedValue = next
            return true
        })

        let hovers = pass.hoverRegions.count
        let taps = pass.tapRegions.count
        let scrolls = pass.scrollRegions.count

        pass.list.append(.pushClip(rect))
        child.render(in: Frame(x: frame.x, y: frame.y - shown, width: frame.width,
                               height: contentHeight),
                     into: &pass)
        if limit > 0, indicator.alpha > 0 {
            // The line is as long as the part that shows, and it is where
            // that part is.
            let part = frame.height / contentHeight
            let length = max(24, frame.height * part)
            let top = frame.y + (frame.height - length) * (shown / limit)
            var line = Path()
            line.addRoundedRectangle(x: frame.x + frame.width - ScrollNode.indicatorWidth - 2,
                                     y: top, width: ScrollNode.indicatorWidth, height: length,
                                     radius: ScrollNode.indicatorWidth / 2)
            pass.list.append(.path(line.scaled(by: pass.scale), color: indicator.premultiplied))
        }
        pass.list.append(.popClip)

        // What the clip hides cannot be pointed at.
        for index in hovers..<pass.hoverRegions.count {
            pass.hoverRegions[index].frame = pass.hoverRegions[index].frame.intersection(frame)
        }
        for index in taps..<pass.tapRegions.count {
            pass.tapRegions[index].frame = pass.tapRegions[index].frame.intersection(frame)
        }
        for index in scrolls..<pass.scrollRegions.count {
            pass.scrollRegions[index].frame = pass.scrollRegions[index].frame.intersection(frame)
        }
    }
}
