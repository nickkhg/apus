import AppKit
import Virtualization

/// The machine in a macOS window (`VM_GPU=window`).
///
/// VZVirtualMachineView draws the screen of the guest and sends the keys and
/// the pointer to the keyboard and the pointing device of the machine.
@MainActor
final class Window: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let runner: Runner
    private var window: NSWindow?

    init(runner: Runner) {
        self.runner = runner
    }

    /// Opens the window and runs until the guest or the window stops.
    func run() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.delegate = self
        application.run()
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = VZVirtualMachineView(
            frame: NSRect(x: 0, y: 0, width: screenWidth, height: screenHeight))
        view.virtualMachine = runner.machine
        // Without this, macOS takes Cmd-Tab and the other system keys, and
        // the guest never sees them.
        view.capturesSystemKeys = true
        // The tests read pixels at fixed positions, so the screen of the
        // guest keeps the size it was configured with.
        view.automaticallyReconfiguresDisplay = false

        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "mydistro"
        window.contentView = view
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the window stops the guest, as closing the QEMU window did.
    func windowWillClose(_ notification: Notification) {
        runner.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ application: NSApplication) -> Bool {
        true
    }
}
