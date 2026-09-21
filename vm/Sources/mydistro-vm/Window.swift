import AppKit
import Virtualization

/// The machine in a macOS window (`VM_GPU=window`).
///
/// VZVirtualMachineView draws the screen of the guest and sends the keys and
/// the pointer to the keyboard and the pointing device of the machine.
@MainActor
final class Window: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let runner: Runner
    private let size: (width: Int, height: Int)
    private let followsWindow: Bool
    /// What `makeCustomGPU` gave back. With a device of our own in it, the
    /// window shows what that device draws. With nothing in it, the window
    /// shows the graphics device of the framework by itself.
    private let customGPU: [AnyObject]
    private var window: NSWindow?

    init(runner: Runner, size: (width: Int, height: Int), followsWindow: Bool,
         customGPU: [AnyObject] = []) {
        self.runner = runner
        self.size = size
        self.followsWindow = followsWindow
        self.customGPU = customGPU
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
            frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        view.virtualMachine = runner.machine
        // Without this, macOS takes Cmd-Tab and the other system keys, and
        // the guest never sees them.
        view.capturesSystemKeys = true
        // A resize of the window resizes the screen of the guest, and the
        // compositor lays out again for the new size. The pixel tests are
        // not affected: they run headless, with no window and no view.
        //
        // The view follows its backing size, not its size in points. A Mac
        // with small pixels therefore gives the guest twice the pixels in
        // each direction, which is four times the work for each frame.
        // VM_RESIZE=off keeps the size that VM_SCREEN asked for.
        view.automaticallyReconfiguresDisplay = followsWindow

        // Our own device draws over that view. The view below keeps the
        // keyboard and the pointer.
        if #available(macOS 27, *), let screen = makeGuestView(for: customGPU) {
            screen.frame = view.bounds
            screen.autoresizingMask = [.width, .height]
            view.addSubview(screen)
        }

        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
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
