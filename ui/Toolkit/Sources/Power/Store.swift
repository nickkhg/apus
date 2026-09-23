import Toolkit

// What Power shows: the last reading of the supplies, and the watts of the
// readings before it, for the row of bars.

public final class PowerStore {
    let source: PowerSource
    /// Called after a new reading.
    public var changed: () -> Void = {}

    public private(set) var reading: PowerReading
    /// The watts of the last readings, oldest first.
    public private(set) var history: [Double] = []
    public var machine: MachineKind { source.machine }

    private var lastRead = -Double.infinity

    /// How often the supplies are read: a battery changes slowly, and the
    /// power that goes out of it changes with the work.
    static let readInterval = 2.0
    /// How many readings the row of bars holds.
    static let historyLength = 30

    public init(source: PowerSource) {
        self.source = source
        reading = PowerReading()
        read()
    }

    /// About once a second.
    public func tick(now: Double) {
        guard now - lastRead >= PowerStore.readInterval else { return }
        lastRead = now
        let before = reading
        read()
        if reading != before || reading.watts != nil { changed() }
    }

    private func read() {
        reading = PowerReading(source.supplies().map { PowerSupply.parse($0.uevent, name: $0.name) })
        if let watts = reading.watts {
            history.append(watts)
            if history.count > PowerStore.historyLength { history.removeFirst() }
        }
    }

    /// What the machine is, in a sentence, for a machine with no battery.
    public var noBatteryReason: String {
        switch machine {
        case .appleVM:
            "This is a virtual machine on a Mac. The Mac has the battery and the "
                + "adapter, and it gives the VM neither, so the charge and the power "
                + "are in macOS."
        case .virtualMachine(let name):
            "This is a virtual machine (\(name)). Its host has the power, and it gives "
                + "the VM no battery and no adapter."
        case .container:
            "This runs in a container. The machine under it has the power, and the "
                + "container sees none of it."
        case .unknown:
            "A machine that runs from the wall with no driver for its adapter looks "
                + "like this, and so does a battery that the kernel has no driver for."
        }
    }
}
