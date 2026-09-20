/// How much room a window has, which says which user interface it draws.
///
/// The class comes from the size that the layout proposes, not from the
/// frame that the window ends with. A window therefore knows what to draw
/// while it is still answering, and it never has to guess from the numbers.
///
/// This lives in the toolkit and not in the shell, because it is a contract
/// between a layout and any app. An app does not depend on the shell of the
/// system.
public enum SizeClass: String, Sendable {
    /// A tile in the band. The app draws a user interface made for it.
    case widget
    /// A narrow window: half of the screen, or a cell of a large grid.
    case compact
    /// A window with room, such as the principal cell.
    case large

    /// A proposal this short or shorter makes a window draw its widget UI.
    public static let widgetLimit: Double = 320
    /// Above this a window is `large`.
    public static let compactLimit: Double = 640

    /// The class for a proposed size. The shorter side decides, because a
    /// window that is 256 across is a tile however long it is.
    public static func of(_ proposal: Proposal) -> SizeClass {
        let sides = [proposal.width, proposal.height].compactMap { $0 }.filter(\.isFinite)
        guard let shortest = sides.min() else { return .large }
        if shortest <= widgetLimit { return .widget }
        if shortest <= compactLimit { return .compact }
        return .large
    }
}
