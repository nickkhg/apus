import Foundation
import Virtualization

/// Writes a line to standard error. The guest console owns standard output,
/// so anything of the tool's own goes to the other one.
func log(_ message: String) {
    FileHandle.standardError.write(Data("apus-vm: \(message)\n".utf8))
}

/// Stops the tool with a message on standard error, after putting the
/// terminal back as it was.
func die(_ message: String) -> Never {
    Terminal.restore()
    FileHandle.standardError.write(Data("apus-vm: \(message)\n".utf8))
    exit(1)
}

/// Starts the machine and stops the tool when the guest stops.
///
/// The expect tests wait for the end of the process after `poweroff`, so the
/// tool must not stay alive when the guest has gone.
@MainActor
final class Runner: NSObject, VZVirtualMachineDelegate {
    let machine: VZVirtualMachine

    /// The machine that the escape combination and the window stop. A
    /// thread that is not the main thread reads the keys, so it reaches the
    /// machine through `requestStop`, which comes back to the main queue.
    nonisolated(unsafe) private static var shared: Runner?

    init(configuration: VZVirtualMachineConfiguration) {
        machine = VZVirtualMachine(configuration: configuration)
        super.init()
        machine.delegate = self
        Runner.shared = self
    }

    func start() {
        machine.start { result in
            if case .failure(let error) = result {
                die("cannot start the machine: \(error.localizedDescription)")
            }
        }
    }

    /// Asks the guest to stop, from any thread.
    nonisolated static func requestStop() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Runner.shared?.stop() }
        }
    }

    func stop() {
        guard machine.canStop else { finish(0) }
        machine.stop { _ in self.finish(0) }
    }

    private func finish(_ code: Int32) -> Never {
        Terminal.restore()
        exit(code)
    }

    // The guest powered itself off (`poweroff` in the tests).
    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { finish(0) }
    }

    nonisolated func virtualMachine(
        _ virtualMachine: VZVirtualMachine, didStopWithError error: any Error
    ) {
        MainActor.assumeIsolated {
            Terminal.restore()
            FileHandle.standardError.write(
                Data("apus-vm: the machine stopped: \(error.localizedDescription)\n".utf8))
            finish(1)
        }
    }

    nonisolated func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: any Error
    ) {
        FileHandle.standardError.write(
            Data("apus-vm: the network stopped: \(error.localizedDescription)\n".utf8))
    }
}
