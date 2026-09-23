@testable import Settings
import Toolkit

/// A machine for the tests: it answers from a snapshot, and it writes down
/// what Settings asked it to do.
final class Machine: SettingsSystem {
    var snapshot: Snapshot
    var calls: [String] = []
    var outcome = Outcome.done("Done")

    init() {
        var snapshot = Snapshot()
        snapshot.about.hostName = "apus"
        snapshot.about.system = "Apus"
        snapshot.about.build = "rolling"
        snapshot.about.kernel = "6.12.9-1-aarch64-ARCH"
        snapshot.about.architecture = "aarch64"
        snapshot.about.processors = 4
        snapshot.about.memory = 4 << 30
        snapshot.about.diskUsed = 5 << 30
        snapshot.about.diskTotal = 31 << 30
        snapshot.about.installed = "2026-09-20"
        snapshot.about.uptime = 4000
        snapshot.about.machineID = "6d79646f0000400080000000000000aa"
        snapshot.about.virtualization = "apple"
        snapshot.time.zone = "Europe/Berlin"
        snapshot.time.networkTime = true
        snapshot.time.synchronized = true
        snapshot.time.zones = Parse.timeZones("""
            AD\t+4230+00131\tEurope/Andorra
            DE,DK,NO,SE,SJ\t+5230+01322\tEurope/Berlin\tmost of Germany
            AR\t-3436-05827\tAmerica/Argentina/Buenos_Aires\tBuenos Aires (BA, CF)
            US\t+404251-0740023\tAmerica/New_York\tEastern (most areas)
            JP\t+353916+1394441\tAsia/Tokyo
            GB,GG,IM,JE\t+513030-0000731\tEurope/London
            """)
        snapshot.password = .none
        snapshot.screens = [ScreenInfo(id: "Virtual-1", mode: "1280x800")]
        snapshot.shellIsService = true
        snapshot.saved = ShellSettings(renderer: .gpu)
        snapshot.running = ShellSettings(renderer: .gpu)
        var wired = NetworkInterface(id: "enp0s1")
        wired.state = "up"
        wired.hardwareAddress = "52:54:00:12:34:56"
        wired.ipv4 = ["192.168.64.7/24"]
        wired.ipv6 = ["fd00::5054:ff:fe12:3456/64"]
        wired.gateway = "192.168.64.1"
        wired.speed = 1000
        snapshot.interfaces = [wired]
        snapshot.nameServers = ["192.168.64.1"]
        snapshot.apps = [
            AppInfo(id: "org.apus.terminal", name: "Terminal", color: Color(hex: 0x3BB273),
                    source: .bundle, program: "bin/apus-terminal"),
            AppInfo(id: "org.apus.system", name: "System", color: Color(hex: 0x49C7C7),
                    source: .bundle, program: "bin/apus-system"),
            AppInfo(id: "chromium", name: "Chromium", color: Color(hex: 0x3070F0),
                    source: .package, program: "/usr/bin/chromium"),
            AppInfo(id: "htop", name: "htop", color: Color(hex: 0xE0A458),
                    source: .package, program: "/usr/bin/htop", isShown: false),
        ]
        snapshot.load = [0.12, 0.08, 0.01]
        self.snapshot = snapshot
    }

    func read(zones: Bool) -> Snapshot {
        var copy = snapshot
        if !zones { copy.time.zones = [] }
        return copy
    }

    func clock() -> ClockReading {
        ClockReading(hour: 14, minute: 5, second: 9, date: "Wednesday 23 September 2026",
                     abbreviation: "CEST", offset: 7200)
    }

    private func record(_ call: String) -> Outcome {
        calls.append(call)
        return outcome
    }

    func setHostName(_ name: String) -> Outcome {
        if case .done = outcome { snapshot.about.hostName = name }
        return record("hostname \(name)")
    }

    func setTimeZone(_ zone: String) -> Outcome {
        if case .done = outcome { snapshot.time.zone = zone }
        return record("zone \(zone)")
    }

    func setNetworkTime(_ on: Bool) -> Outcome {
        snapshot.time.networkTime = on
        return record("ntp \(on)")
    }

    func setPassword(_ password: String?) -> Outcome {
        snapshot.password = password == nil ? .none : .set
        return record("password \(password ?? "none")")
    }

    func saveShellSettings(_ settings: ShellSettings) -> Outcome {
        snapshot.saved = settings
        return record("save \(Parse.dropIn(for: settings).split(separator: "\n").dropFirst(3).joined(separator: " "))")
    }

    func renew(_ interface: String) -> Outcome { record("renew \(interface)") }

    func setShown(_ app: AppInfo, _ shown: Bool) -> Outcome {
        if let index = snapshot.apps.firstIndex(where: { $0.id == app.id }) {
            snapshot.apps[index].isShown = shown
        }
        return record("shown \(app.id) \(shown)")
    }

    func restartShell() -> Outcome { record("restart shell") }
    func restartMachine() -> Outcome { record("reboot") }
    func powerOff() -> Outcome { record("poweroff") }
}

extension KeyEvent {
    static let up = KeyEvent(keysym: 0xFF52)
    static let down = KeyEvent(keysym: 0xFF54)
    static let left = KeyEvent(keysym: 0xFF51)
    static let enter = KeyEvent(keysym: 0xFF0D)
    static let escape = KeyEvent(keysym: 0xFF1B)
    static let tab = KeyEvent(keysym: 0xFF09)
    static let backspace = KeyEvent(keysym: 0xFF08)
    static let space = KeyEvent(keysym: 0x20, characters: " ")

    static func typing(_ text: String) -> [KeyEvent] {
        text.map { KeyEvent(keysym: 0x61, characters: String($0)) }
    }
}

extension SettingsStore {
    func type(_ text: String) {
        for key in KeyEvent.typing(text) { self.key(key) }
    }
}
