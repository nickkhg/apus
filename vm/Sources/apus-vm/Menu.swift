import AppKit

/// The menu bar of the window.
///
/// Without a menu the window has no Quit, no Hide and no About: macOS gives
/// an application those only through its menu.
///
/// The Debug menu turns things on and off, and nothing else. What they say
/// is drawn over the screen of the guest, where it can be read while the
/// guest is used. Each switch is kept, so a window opens as the last one
/// closed.
@MainActor
enum Menu {
    private static let defaults = UserDefaults.standard

    enum Switch: String, CaseIterable {
        case frames = "debug.frames"
        case device = "debug.device"

        var title: String {
            switch self {
            case .frames: "Frames a Second"
            case .device: "GPU Device Counters"
            }
        }

        /// The key that turns it on, with Command and Option.
        var key: String {
            switch self {
            case .frames: "f"
            case .device: "g"
            }
        }

        var startsOn: Bool { self == .frames }
    }

    static func on(_ name: Switch) -> Bool {
        defaults.object(forKey: name.rawValue) as? Bool ?? name.startsOn
    }

    static func install(stop: @escaping () -> Void, changed: @escaping (Switch) -> Void) {
        Actions.shared.stop = stop
        Actions.shared.changed = changed

        let bar = NSMenu()
        let application = NSMenuItem()
        application.submenu = applicationMenu()
        bar.addItem(application)

        let debug = NSMenuItem()
        debug.submenu = debugMenu()
        bar.addItem(debug)

        NSApp.mainMenu = bar
    }

    private static func applicationMenu() -> NSMenu {
        let name = "Apus"
        let menu = NSMenu(title: name)
        menu.addItem(withTitle: "About \(name)", action: #selector(
            NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")
        let others = menu.addItem(withTitle: "Hide Others",
                                  action: #selector(NSApplication.hideOtherApplications(_:)),
                                  keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())

        // Quit stops the guest first. Ending the process while the machine
        // runs leaves the disk as the guest last wrote it.
        let quit = NSMenuItem(title: "Quit \(name)", action: #selector(Actions.quit(_:)),
                              keyEquivalent: "q")
        quit.target = Actions.shared
        menu.addItem(quit)
        return menu
    }

    private static func debugMenu() -> NSMenu {
        let menu = NSMenu(title: "Debug")
        for name in Switch.allCases {
            let item = NSMenuItem(title: name.title, action: #selector(Actions.toggle(_:)),
                                  keyEquivalent: name.key)
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = Actions.shared
            item.representedObject = name.rawValue
            item.state = on(name) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// The target of the menu items. NSMenuItem wants an object.
    @MainActor
    final class Actions: NSObject {
        static let shared = Actions()
        var stop: () -> Void = {}
        var changed: (Switch) -> Void = { _ in }

        @objc func quit(_ sender: Any?) { stop() }

        @objc func toggle(_ sender: Any?) {
            guard let item = sender as? NSMenuItem,
                  let key = item.representedObject as? String,
                  let name = Switch(rawValue: key) else { return }
            let next = !Menu.on(name)
            Menu.defaults.set(next, forKey: key)
            item.state = next ? .on : .off
            changed(name)
        }
    }
}
