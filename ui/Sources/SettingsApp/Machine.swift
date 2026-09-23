import Glibc
import Settings
import Toolkit

// This machine, as Settings sees it: every value comes from a file of the
// kernel, a file of the system, or a call of the C library, and every
// change goes to the file that the system reads, or to the program of the
// system that owns it.
//
// Everything runs as root on Apus, so Settings writes /etc itself. See
// docs/settings.md for which file each pane reads and writes.

final class Machine: SettingsSystem {
    /// The desktop entry that each app of a package came from, so that
    /// hiding one copies the right file.
    private var entries: [String: String] = [:]
    /// What runs the machine does not change while it runs.
    private lazy var virtualization: String = {
        let result = Command.run(["systemd-detect-virt"])
        let value = result.output.split(separator: "\n").first.map(String.init) ?? ""
        return result.succeeded && value != "none" ? value : ""
    }()

    static let zoneDirectory = "/usr/share/zoneinfo"
    static let timesyncLink = "/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service"

    // MARK: - Reading

    func read(zones: Bool) -> Snapshot {
        var snapshot = Snapshot()
        snapshot.about = about()
        snapshot.time = time(zones: zones)
        snapshot.password = Parse.password(inShadow: Files.read("/etc/shadow") ?? "")
        snapshot.screens = screens()
        snapshot.running = Parse.shellSettings(environment())
        snapshot.saved = Parse.shellSettings(
            Parse.unitEnvironment(Files.read(Parse.dropInPath) ?? ""))
        snapshot.shellIsService = shellIsService()
        snapshot.interfaces = interfaces()
        snapshot.nameServers = Parse.nameServers(
            Files.read("/run/systemd/resolve/resolv.conf") ?? Files.read("/etc/resolv.conf") ?? "")
        snapshot.apps = apps()
        snapshot.sounds = SoundSettings.load()
        snapshot.load = (Files.line("/proc/loadavg") ?? "")
            .split(separator: " ").prefix(3).compactMap { Double($0) }
        return snapshot
    }

    private func about() -> About {
        var about = About()
        about.hostName = hostName()
        let release = Parse.assignments(Files.read("/etc/os-release") ?? "")
        about.system = release["PRETTY_NAME"] ?? release["NAME"] ?? "Apus"
        about.build = release["BUILD_ID"] ?? release["VERSION_ID"] ?? ""
        var names = utsname()
        if uname(&names) == 0 {
            about.kernel = field(&names.release)
            about.architecture = field(&names.machine)
        }
        about.processors = Int(sysconf(Int32(_SC_NPROCESSORS_ONLN)))
        for line in (Files.read("/proc/meminfo") ?? "").split(separator: "\n")
        where line.hasPrefix("MemTotal:") {
            let kibibytes = line.split(separator: " ").dropFirst().first.flatMap { UInt64($0) } ?? 0
            about.memory = kibibytes * 1024
        }
        var disk = statvfs()
        if statvfs("/", &disk) == 0 {
            let unit = UInt64(disk.f_frsize)
            about.diskTotal = UInt64(disk.f_blocks) * unit
            let free = UInt64(disk.f_bavail) * unit
            about.diskUsed = about.diskTotal > free ? about.diskTotal - free : 0
        }
        about.installed = Files.line("/etc/apus-installed").flatMap { $0.isEmpty ? nil : $0 }
        about.isLive = (Files.line("/proc/cmdline") ?? "").split(separator: " ").contains("apus.live")
        about.uptime = (Files.line("/proc/uptime") ?? "").split(separator: " ").first
            .flatMap { Double($0) } ?? 0
        about.machineID = Files.line("/etc/machine-id") ?? ""
        about.virtualization = virtualization
        return about
    }

    private func hostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else {
            return Files.line("/etc/hostname") ?? ""
        }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private func time(zones: Bool) -> TimeSettings {
        var time = TimeSettings()
        time.zone = Files.target(of: "/etc/localtime").flatMap(Parse.zone(fromLink:)) ?? "UTC"
        time.networkTime = Files.exists(Machine.timesyncLink)
        time.synchronized = Files.exists("/run/systemd/timesync/synchronized")
        if zones {
            time.zones = Parse.timeZones(Files.read("\(Machine.zoneDirectory)/zone1970.tab") ?? "")
        }
        return time
    }

    /// The connectors of the display devices that have a screen on them.
    private func screens() -> [ScreenInfo] {
        let base = "/sys/class/drm"
        return Files.names(in: base).compactMap { name in
            // card0-Virtual-1: a connector. card0 alone is the device.
            guard name.hasPrefix("card"), let dash = name.firstIndex(of: "-"),
                  Files.line("\(base)/\(name)/status") == "connected" else { return nil }
            return ScreenInfo(id: String(name[name.index(after: dash)...]),
                              mode: Parse.preferredMode(Files.read("\(base)/\(name)/modes") ?? ""))
        }
    }

    /// The environment of this program, which is the environment that the
    /// shell started it with.
    private func environment() -> [String: String] {
        var result: [String: String] = [:]
        var entry = environ
        while let text = entry.pointee {
            defer { entry += 1 }
            let line = String(cString: text)
            if let equals = line.firstIndex(of: "=") {
                result[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        return result
    }

    /// Whether systemd started the shell, which is whether it can start it
    /// again. An app is in the control group of the shell that started it.
    private func shellIsService() -> Bool {
        (Files.read("/proc/self/cgroup") ?? "").contains("/apus-shell.service")
    }

    private func interfaces() -> [NetworkInterface] {
        let base = "/sys/class/net"
        let gateways = Parse.gateways(Files.read("/proc/net/route") ?? "")
        var addresses: [String: (v4: [String], v6: [String])] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0 {
            var item = list
            while let current = item {
                defer { item = current.pointee.ifa_next }
                guard let address = current.pointee.ifa_addr else { continue }
                let name = String(cString: current.pointee.ifa_name)
                let family = Int32(address.pointee.sa_family)
                guard family == AF_INET || family == AF_INET6,
                      let text = Machine.text(of: address) else { continue }
                let prefix = current.pointee.ifa_netmask.map { Machine.prefixLength(of: $0) }
                let written = prefix.map { "\(text)/\($0)" } ?? text
                if family == AF_INET {
                    addresses[name, default: ([], [])].v4.append(written)
                } else {
                    addresses[name, default: ([], [])].v6.append(written)
                }
            }
            freeifaddrs(list)
        }
        return Files.names(in: base).filter { $0 != "lo" }.map { name in
            var interface = NetworkInterface(id: name)
            interface.state = Files.line("\(base)/\(name)/operstate") ?? ""
            interface.hardwareAddress = Files.line("\(base)/\(name)/address") ?? ""
            interface.kind = Files.isDirectory("\(base)/\(name)/wireless") ? .wireless
                : (Files.line("\(base)/\(name)/type") == "1" ? .wired : .other)
            interface.speed = max(0, Int(Files.line("\(base)/\(name)/speed") ?? "") ?? 0)
            interface.ipv4 = addresses[name]?.v4 ?? []
            // A link-local address is on every interface and reaches only
            // the next machine, so it comes after the others.
            let v6 = addresses[name]?.v6 ?? []
            interface.ipv6 = v6.filter { !$0.hasPrefix("fe80") } + v6.filter { $0.hasPrefix("fe80") }
            interface.gateway = gateways[name] ?? ""
            return interface
        }
    }

    private static func text(of address: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = Int32(address.pointee.sa_family)
        let written: UnsafePointer<CChar>? = if family == AF_INET {
            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
                inet_ntop(AF_INET, &inet.pointee.sin_addr, &buffer, socklen_t(buffer.count))
            }
        } else {
            address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { inet in
                inet_ntop(AF_INET6, &inet.pointee.sin6_addr, &buffer, socklen_t(buffer.count))
            }
        }
        guard written != nil else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// The number of bits that a netmask sets.
    private static func prefixLength(of mask: UnsafeMutablePointer<sockaddr>) -> Int {
        let family = Int32(mask.pointee.sa_family)
        if family == AF_INET {
            return mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr.nonzeroBitCount
            }
        }
        return mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { inet in
            withUnsafeBytes(of: &inet.pointee.sin6_addr) { $0.reduce(0) { $0 + $1.nonzeroBitCount } }
        }
    }

    // MARK: - Apps

    /// The apps of /Applications, and then the apps of the packages that
    /// Summon lists or could list, in the order of their names.
    private func apps() -> [AppInfo] {
        var result: [AppInfo] = []
        var taken = Set<String>()
        for bundle in Files.names(in: "/Applications") where bundle.hasSuffix(".app") {
            let manifest = Parse.assignments(Files.read("/Applications/\(bundle)/app.conf") ?? "")
            guard let id = manifest["id"], let name = manifest["name"] else { continue }
            taken.insert(id)
            result.append(AppInfo(id: id, name: name,
                                  color: Color(hex: Parse.colour(manifest["color"]) ?? 0x6C777D),
                                  source: .bundle, program: manifest["exec"] ?? ""))
        }
        var packages: [AppInfo] = []
        entries = [:]
        for directory in Machine.entryDirectories() {
            for file in Files.names(in: directory) where file.hasSuffix(".desktop") {
                let id = String(file.dropLast(".desktop".count))
                guard !taken.contains(id) else { continue }
                taken.insert(id)
                let path = "\(directory)/\(file)"
                let entry = Parse.desktopEntry(Files.read(path) ?? "")
                // The same rules as the compositor, except NoDisplay: an app
                // that is hidden is still one that a person can show.
                guard entry["Type"] == "Application", entry["Hidden"] != "true",
                      entry["Terminal"] != "true", let name = entry["Name"], !name.isEmpty,
                      let exec = entry["Exec"], Machine.resolve(Parse.program(ofExec: exec)) != nil
                else { continue }
                entries[id] = path
                packages.append(AppInfo(id: id, name: name, color: Color(hex: Parse.colour(forID: id)),
                                        source: .package, program: Parse.program(ofExec: exec),
                                        isShown: entry["NoDisplay"] != "true"))
            }
        }
        return result.sorted { $0.name < $1.name } + packages.sorted {
            $0.name.lowercased() < $1.name.lowercased()
        }
    }

    /// Where a person's own desktop entries go. The first one wins.
    static var userEntries: String {
        if let home = value("XDG_DATA_HOME"), !home.isEmpty { return "\(home)/applications" }
        let home = value("HOME").flatMap { $0.isEmpty ? nil : $0 } ?? "/root"
        return "\(home)/.local/share/applications"
    }

    /// The directories of desktop entries, as DesktopEntries.directories()
    /// in the compositor has them.
    static func entryDirectories() -> [String] {
        let shared = value("XDG_DATA_DIRS").flatMap { $0.isEmpty ? nil : $0 }
            ?? "/usr/local/share:/usr/share"
        return [userEntries] + shared.split(separator: ":").map { "\($0)/applications" }
    }

    static func resolve(_ program: String) -> String? {
        guard !program.isEmpty else { return nil }
        if program.contains("/") { return access(program, X_OK) == 0 ? program : nil }
        let path = value("PATH") ?? "/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") where !directory.isEmpty {
            if access("\(directory)/\(program)", X_OK) == 0 { return "\(directory)/\(program)" }
        }
        return nil
    }

    private static func value(_ name: String) -> String? {
        getenv(name).map { String(cString: $0) }
    }

    // MARK: - The clock

    func clock() -> ClockReading {
        // A new zone is a new link at /etc/localtime. tzset reads it again
        // when it changed; localtime_r alone would keep the old one.
        tzset()
        var now = Glibc.time(nil)
        var parts = tm()
        localtime_r(&now, &parts)
        let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let months = ["January", "February", "March", "April", "May", "June", "July",
                      "August", "September", "October", "November", "December"]
        let day = days.indices.contains(Int(parts.tm_wday)) ? days[Int(parts.tm_wday)] : ""
        let month = months.indices.contains(Int(parts.tm_mon)) ? months[Int(parts.tm_mon)] : ""
        return ClockReading(hour: Int(parts.tm_hour), minute: Int(parts.tm_min),
                            second: Int(parts.tm_sec),
                            date: "\(day) \(parts.tm_mday) \(month) \(1900 + parts.tm_year)",
                            abbreviation: parts.tm_zone.map { String(cString: $0) } ?? "",
                            offset: Int(parts.tm_gmtoff))
    }

    // MARK: - Changes

    func setHostName(_ name: String) -> Outcome {
        if let problem = Files.write("/etc/hostname", name + "\n") { return .failed(problem) }
        guard sethostname(name, name.utf8.count) == 0 else {
            return .failed(Files.failure("The kernel did not take the name"))
        }
        return .done("This machine is \(name) now")
    }

    func setTimeZone(_ zone: String) -> Outcome {
        let file = "\(Machine.zoneDirectory)/\(zone)"
        guard Files.exists(file) else { return .failed("\(file) is not there: is tzdata installed?") }
        // The same link that the image has, and that timedatectl makes.
        if let problem = Files.link("/etc/localtime", to: "../usr/share/zoneinfo/\(zone)") {
            return .failed(problem)
        }
        tzset()
        return .done("The clock keeps the time of \(TimeZoneEntry(id: zone).city) now")
    }

    func setNetworkTime(_ on: Bool) -> Outcome {
        let result = Command.run(["systemctl", on ? "enable" : "disable", "--now",
                                  "systemd-timesyncd.service"])
        guard result.succeeded else { return .failed("systemctl: \(result.reason)") }
        return .done(on ? "The clock asks a time server for the time"
                        : "The clock keeps its own time")
    }

    func setPassword(_ password: String?) -> Outcome {
        guard let password else {
            let result = Command.run(["passwd", "-d", "root"])
            return result.succeeded ? .done("root has no password now")
                                    : .failed("passwd: \(result.reason)")
        }
        let result = Command.run(["chpasswd"], input: "root:\(password)\n")
        return result.succeeded ? .done("root has a new password")
                                : .failed("chpasswd: \(result.reason)")
    }

    func saveShellSettings(_ settings: ShellSettings) -> Outcome {
        if settings == ShellSettings() {
            // Nothing to say that the shell does not decide by itself.
            if let problem = Files.remove(Parse.dropInPath) { return .failed(problem) }
        } else {
            if let problem = Files.makeDirectories(Parse.dropInDirectory) { return .failed(problem) }
            if let problem = Files.write(Parse.dropInPath, Parse.dropIn(for: settings)) {
                return .failed(problem)
            }
        }
        let reload = Command.run(["systemctl", "daemon-reload"])
        guard reload.succeeded else { return .failed("systemctl: \(reload.reason)") }
        return .done(shellIsService() ? "Saved. The shell reads this when it starts again."
                                      : "Saved for apus-shell.service. This shell was started by hand.")
    }

    func renew(_ interface: String) -> Outcome {
        let result = Command.run(["networkctl", "reconfigure", interface])
        return result.succeeded ? .done("\(interface) asks for its address again")
                                : .failed("networkctl: \(result.reason)")
    }

    func setShown(_ app: AppInfo, _ shown: Bool) -> Outcome {
        let own = "\(Machine.userEntries)/\(app.id).desktop"
        if shown {
            guard let text = Files.read(own), text.hasPrefix(Parse.hiddenMarker) else {
                return .failed("\(own) hides \(app.name), and Settings did not write it")
            }
            if let problem = Files.remove(own) { return .failed(problem) }
            return .done("Summon lists \(app.name) again")
        }
        guard let source = entries[app.id], let text = Files.read(source) else {
            return .failed("The desktop entry of \(app.name) cannot be read")
        }
        if let problem = Files.makeDirectories(Machine.userEntries) { return .failed(problem) }
        if let problem = Files.write(own, Parse.hiding(text)) { return .failed(problem) }
        return .done("Summon does not list \(app.name). \(own) says so.")
    }

    func saveSounds(_ settings: SoundSettings) -> Outcome {
        let path = SoundSettings.path()
        if settings == SoundSettings() {
            // No file is the default.
            if let problem = Files.remove(path) { return .failed(problem) }
        } else {
            let directory = String(path[..<(path.lastIndex(of: "/") ?? path.endIndex)])
            if let problem = Files.makeDirectories(directory) { return .failed(problem) }
            if let problem = Files.write(path, settings.text) { return .failed(problem) }
        }
        return .done(settings.enabled ? "Saved" : "The system makes no sounds now")
    }

    func play(_ sound: SystemSound) { playSound(sound) }

    /// The sound of the end of a session, before the session ends. systemd
    /// stops the player with the shell, so the change waits for the sound
    /// to play out: it is 0.6 s long.
    private func sayGoodbye() {
        if playSound(.desktopLogout) { usleep(650_000) }
    }

    func restartShell() -> Outcome {
        guard shellIsService() else {
            return .failed("This shell was started by hand, so systemd cannot start it again")
        }
        sayGoodbye()
        // --no-block: the shell that stops takes this app with it, so
        // nothing would be left to hear the answer.
        let result = Command.run(["systemctl", "--no-block", "restart", "apus-shell.service"])
        return result.succeeded ? .done("The shell starts again") : .failed("systemctl: \(result.reason)")
    }

    func restartMachine() -> Outcome {
        sayGoodbye()
        let result = Command.run(["systemctl", "reboot"])
        return result.succeeded ? .done("The machine starts again") : .failed("systemctl: \(result.reason)")
    }

    func powerOff() -> Outcome {
        sayGoodbye()
        let result = Command.run(["systemctl", "poweroff"])
        return result.succeeded ? .done("The machine stops") : .failed("systemctl: \(result.reason)")
    }
}

/// The text of a fixed array of C characters, as utsname holds them.
private func field<T>(_ value: inout T) -> String {
    withUnsafePointer(to: &value) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
    }
}
