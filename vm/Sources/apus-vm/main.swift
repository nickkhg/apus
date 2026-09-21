// apus-vm: boots the Apus images in a virtual machine on the Mac,
// with Apple's Virtualization framework.
//
//   apus-vm live        live image + blank target disk (to test the installer)
//   apus-vm installed   target disk only (boot what the installer wrote)
//
// VM_GPU selects the display:
//   (unset)    no display device; serial console only
//   window     a virtio graphics device in a macOS window, with a keyboard
//              and a pointer. A resize of the window resizes the screen of
//              the guest.
//   headless   a virtio graphics device with no window. The tests read the
//              screen in the guest and write it to the `screens` share,
//              because Virtualization has no screenshot of its own.
//
// VM_SCREEN sets the size of the screen, for example 1920x1200. The default
// is 1280x800, which is the size that the pixel tests read.
//
// The serial console is always on stdin and stdout. Ctrl-A X stops the
// machine. out/ on the Mac is shared read-only with the guest at /mnt/host.

import Foundation
import Virtualization

setbuf(stdout, nil)

// Before anything makes a Metal device. See MetalValidation.swift.
MetalValidation.quieten()

let options: Options
do {
    options = try Options.parse(
        arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
} catch {
    die(error.description)
}

let layout = Layout()
let configuration: VZVirtualMachineConfiguration
do {
    configuration = try makeConfiguration(options, layout)
} catch let error as MachineError {
    die(error.description)
} catch {
    die(error.localizedDescription)
}

// From here on the terminal is raw, so every exit goes through die() or
// Runner, which put it back.
Terminal.onQuit = { Runner.requestStop() }
Terminal.start()
// Everything the guest writes goes out as before, and the window reads the
// frame times out of it on the way.
GuestConsole.start()

// The custom device is held here: the framework's provider keeps only a
// weak reference to its delegate.
let customGPU = makeCustomGPU(options, configuration)

let runner = Runner(configuration: configuration)
runner.start()

switch options.display {
case .window:
    Window(runner: runner, size: options.screen,
           followsWindow: options.followsWindow, customGPU: customGPU).run()
case .none, .headless:
    if #available(macOS 27, *) { attachSnapshot(to: customGPU) }
    RunLoop.main.run()
}
