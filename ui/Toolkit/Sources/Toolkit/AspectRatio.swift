import Render

/// How a view uses the space when it must keep its proportions.
public enum ContentMode: Sendable {
    /// As large as possible, and completely in the space.
    case fit
    /// As small as possible, and over the whole space.
    case fill
}

extension View {
    /// Keeps the proportions of the view. The ratio is the width divided by
    /// the height: 16 / 9 is wide, 1 is square.
    public func aspectRatio(_ ratio: Double, contentMode: ContentMode = .fit) -> AspectRatioView<Self> {
        AspectRatioView(content: self, ratio: ratio, mode: contentMode)
    }

    /// Keeps the proportions that the view asks for.
    public func aspectRatio(contentMode: ContentMode) -> AspectRatioView<Self> {
        AspectRatioView(content: self, ratio: nil, mode: contentMode)
    }

    /// The view keeps its proportions and stays in the space.
    public func scaledToFit() -> AspectRatioView<Self> {
        aspectRatio(contentMode: .fit)
    }

    /// The view keeps its proportions and covers the space.
    public func scaledToFill() -> AspectRatioView<Self> {
        aspectRatio(contentMode: .fill)
    }
}

/// A view with fixed proportions.
public struct AspectRatioView<Content: View>: View {
    public typealias Body = Never
    let content: Content
    /// `nil`: use the proportions of the content.
    let ratio: Double?
    let mode: ContentMode

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        nodes.append(AspectRatioNode(child: content.node(environment: environment),
                                     ratio: ratio, mode: mode))
    }
}

final class AspectRatioNode: LayoutNode {
    let child: LayoutNode
    let ratio: Double?
    let mode: ContentMode

    init(child: LayoutNode, ratio: Double?, mode: ContentMode) {
        self.child = child
        self.ratio = ratio
        self.mode = mode
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        // The child gets a space with the right proportions, and it answers
        // with the size that it wants. A child with a fixed size keeps it.
        child.size(fitting: Proposal(box(for: proposal)))
    }

    /// The largest size with the correct proportions that is in the space
    /// (`fit`), or the smallest one that covers it (`fill`).
    private func box(for proposal: Proposal) -> Size {
        guard let ratio = ratio ?? contentRatio(), ratio > 0, ratio.isFinite else {
            return child.size(fitting: proposal)
        }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil }

        switch (width, height) {
        case (let width?, let height?):
            let widthLimits = mode == .fit ? width / height < ratio : width / height > ratio
            return widthLimits
                ? Size(width: width, height: width / ratio)
                : Size(width: height * ratio, height: height)
        case (let width?, nil):
            return Size(width: width, height: width / ratio)
        case (nil, let height?):
            return Size(width: height * ratio, height: height)
        case (nil, nil):
            let ideal = child.size(fitting: .unspecified)
            let length = max(ideal.width, ideal.height * ratio)
            return Size(width: length, height: length / ratio)
        }
    }

    /// The proportions that the content asks for.
    private func contentRatio() -> Double? {
        let ideal = child.size(fitting: .unspecified)
        guard ideal.height > 0 else { return nil }
        return ideal.width / ideal.height
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        let size = child.size(fitting: Proposal(box(for: Proposal(frame.size))))
        let offset = Alignment.center.offset(for: size, in: frame.size)
        child.render(in: Frame(origin: (frame.x + offset.x, frame.y + offset.y), size: size),
                     into: &pass)
    }
}
