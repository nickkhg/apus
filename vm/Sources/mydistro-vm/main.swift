// mydistro-vm: boots the mydistro images in a virtual machine on the Mac,
// with Apple's Virtualization framework.
//
//   mydistro-vm live        live image + blank target disk (to test the installer)
//   mydistro-vm installed   target disk only (boot what the installer wrote)
//
// VM_GPU selects the display:
//   (unset)    no display device; serial console only
//   window     a virtio graphics device in a macOS window, with a keyboard
//              and a pointer
//   headless   a virtio graphics device with no window. The tests read the
//              screen in the guest and write it to the `screens` share,
//              because Virtualization has no screenshot of its own.
//
// The serial console is always on stdin and stdout. Ctrl-A X stops the
// machine. out/ on the Mac is shared read-only with the guest at /mnt/host.

import Foundation
import Virtualization

setbuf(stdout, nil)

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

let runner = Runner(configuration: configuration)
runner.start()

switch options.display {
case .window:
    Window(runner: runner).run()
case .none, .headless:
    RunLoop.main.run()
}
