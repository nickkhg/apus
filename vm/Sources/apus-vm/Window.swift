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
    /// The screen of our own device, when the machine has one.
    private var guestView: NSView?
    /// The numbers over the screen of the guest.
    private var overlay: Overlay?

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
        Menu.install(stop: { [runner] in runner.stop() },
                     changed: { [weak self] name in self?.apply(name) })
        GuestConsole.watch { Counters.shared.read($0) }

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

        // Everything of ours is beside that view and not inside it.
        // VZVirtualMachineView draws the guest itself, and it stops drawing
        // it as soon as it is given a subview: the window then shows black,
        // with whatever was added over the top of it.
        let content = NSView(frame: view.frame)
        content.autoresizesSubviews = true
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)

        // With a device of our own, that device draws the screen of the
        // guest and the framework draws nothing for it. A view over the
        // view of the framework shows what it draws. The view below keeps
        // the keyboard and the pointer.
        if #available(macOS 27, *) { attachGuestView(to: content, frame: view.frame) }

        // The numbers go last, so they are above everything.
        let overlay = Overlay(frame: .zero)
        // Fixed to the top left: the right and the bottom margins give.
        overlay.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(overlay)
        self.overlay = overlay
        apply(.frames)
        apply(.device)

        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Apus"
        window.contentView = content
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    /// Puts the screen of our own device in the window, when the machine
    /// has one. With no such device the window shows the display of the
    /// framework, as before.
    @available(macOS 27, *)
    private func attachGuestView(to content: NSView, frame: NSRect) {
        guard let device = customGPU.compactMap({ $0 as? VirtioGPUDevice }).first else {
            // No device of ours: only VM_SNAPSHOT wants the pictures.
            attachSnapshot(to: customGPU)
            return
        }
        let guestView = GuestView(frame: frame)
        guestView.autoresizingMask = [.width, .height]
        content.addSubview(guestView)
        self.guestView = guestView
        device.screen = withSnapshot(GuestWindowScreen(view: guestView))
    }

    /// A switch of the Debug menu changed.
    private func apply(_ name: Menu.Switch) {
        switch name {
        case .frames: overlay?.showsFrames = Menu.on(.frames)
        case .device: overlay?.showsDevice = Menu.on(.device)
        }
    }

    /// Closing the window stops the guest, as closing the QEMU window did.
    func windowWillClose(_ notification: Notification) {
        runner.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ application: NSApplication) -> Bool {
        true
    }
}
