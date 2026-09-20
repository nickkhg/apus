import Toolkit

/// An app that the system can start.
///
/// Each app is a bundle in /Applications. The compositor reads the bundles
/// and puts one AppEntry in `ShellState` for each of them, so the shell needs
/// no file system and no process of its own. See docs/applications.md.
public struct AppEntry: Identifiable, Equatable, Sendable {
    /// The id of the app, for example "org.mydistro.terminal". A window of
    /// the app gives the same id in xdg_toplevel.set_app_id, and that is how
    /// the shell knows which app a window belongs to.
    public let id: String
    /// The name in the dock. Its first letter is in the icon.
    public let name: String
    /// The colour of the icon.
    public let color: Color

    public init(id: String, name: String, color: Color) {
        self.id = id
        self.name = name
        self.color = color
    }
}
