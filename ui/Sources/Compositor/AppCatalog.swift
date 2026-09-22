import Glibc
import Shell
import Toolkit

// The apps of the system live in /Applications. Each app is a bundle: a
// directory whose name ends in ".app", with a manifest and the program in it.
//
//     /Applications/Terminal.app/
//         app.conf           the manifest
//         bin/apus-terminal
//
// The manifest is a list of "key = value" lines. A line that starts with "#"
// is a comment:
//
//     id = org.apus.terminal
//     name = Terminal
//     exec = bin/apus-terminal
//     color = 3BB273
//
// The compositor reads the bundles when it starts, shows one dock icon for
// each of them, and starts the program of the bundle when the icon is
// clicked. See docs/applications.md.
//
// A program that came from a package has no bundle. It has the desktop entry
// that it ships, in /usr/share/applications, and DesktopEntries.swift reads
// those into the same list, so that `pacman -S chromium` is enough to put
// Chromium in Summon.

/// One app that Summon can start: a bundle of /Applications, or a desktop
/// entry of a package.
struct AppBundle {
    /// The id of the app. A window of the app gives the same id in
    /// xdg_toplevel.set_app_id.
    let id: String
    let name: String
    /// The colour of the icon, 0xRRGGBB.
    let color: UInt32
    /// The program to start, as an absolute path, and its arguments. A
    /// bundle names a program alone; a desktop entry can name arguments
    /// with it.
    let arguments: [String]

    /// The program and its arguments as one line, for a card that says an
    /// app did not start.
    var command: String { arguments.joined(separator: " ") }

    /// What the dock shows.
    var entry: AppEntry { AppEntry(id: id, name: name, color: Color(hex: color)) }
}

enum AppCatalog {
    /// Where the bundles are.
    static let directory = "/Applications"
    /// The `posix_spawn` flags of glibc. The C headers give them to the
    /// preprocessor only, so Swift does not see them.
    private static let spawnSetSID: Int32 = 0x80
    private static let spawnSetSigDefault: Int32 = 0x04
    private static let spawnSetSigMask: Int32 = 0x08

    /// Sets a child up to start with the signals as a program expects them.
    ///
    /// A process that ignores a signal passes that on through `exec`, and so
    /// does a process that blocks one. The compositor does both: it ignores
    /// SIGCHLD, so that it never has to wait for an app it started, and its
    /// event loop blocks SIGINT and SIGTERM to read them from a file
    /// descriptor instead. Neither belongs to the app.
    ///
    /// A program that inherits an ignored SIGCHLD cannot wait for its own
    /// children: the kernel takes each one away as it ends, and `waitpid`
    /// answers "no child processes". pacman waits for a child for every
    /// package it installs and every hook it runs, so an install inside
    /// Apus failed on each of them.
    static func resetSignals(_ attributes: inout posix_spawnattr_t) -> Int32 {
        // Every signal goes back to its default action. SIGKILL and SIGSTOP
        // have no action to set, and asking would only fail.
        var defaulted = sigset_t()
        sigfillset(&defaulted)
        sigdelset(&defaulted, SIGKILL)
        sigdelset(&defaulted, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaulted)
        // And nothing is blocked.
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        return spawnSetSigDefault | spawnSetSigMask
    }

    /// Every app that the machine offers, by name: the bundles of
    /// `directory` first, and then the desktop entries of the packages that
    /// are installed. A bundle wins over a desktop entry with the same id,
    /// so an app of Apus keeps its name and its colour.
    static func bundles(in directory: String = AppCatalog.directory,
                        desktopDirectories: [String]? = nil) -> [AppBundle] {
        var found = bundlesOnly(in: directory)
        var taken = Set(found.map(\.id))
        let entries = DesktopEntries.apps(in: desktopDirectories ?? DesktopEntries.directories())
        for app in entries where taken.insert(app.id).inserted {
            found.append(app)
        }
        debug("\(found.count) apps: \(found.count - entries.count) bundles, "
            + "\(entries.count) desktop entries")
        return found.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The bundles in `directory`, by name.
    ///
    /// With APUS_UI_DIR set (`make test-dev` and `make demo-dev` set it),
    /// a program of that directory takes the place of the installed one with
    /// the same name. Then a bundle starts the new build.
    static func bundlesOnly(in directory: String = AppCatalog.directory) -> [AppBundle] {
        guard let handle = opendir(directory) else {
            debug("no \(directory): only the apps of the packages")
            return []
        }
        defer { closedir(handle) }
        var bundles: [AppBundle] = []
        while let record = readdir(handle) {
            var entry = record.pointee
            let name = withUnsafePointer(to: &entry.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX)) { String(cString: $0) }
            }
            guard name.hasSuffix(".app") else { continue }
            let path = "\(directory)/\(name)"
            if let bundle = read(bundleAt: path) {
                bundles.append(bundle)
            } else {
                log("compositor: \(path) has no usable app.conf")
            }
        }
        return bundles.sorted { $0.name < $1.name }
    }

    /// Reads the manifest of one bundle. A bundle needs an id, a name and a
    /// program that exists.
    static func read(bundleAt path: String) -> AppBundle? {
        guard let text = contents(of: "\(path)/app.conf") else { return nil }
        let settings = parse(text)
        guard let id = settings["id"], let name = settings["name"],
              let command = program(settings["exec"], in: path) else { return nil }
        let color = settings["color"].flatMap { UInt32($0, radix: 16) } ?? 0x8A8A8A
        return AppBundle(id: id, name: name, color: color, arguments: [command])
    }

    /// The path of the program of a bundle. `exec` is a path in the bundle,
    /// or an absolute path.
    private static func program(_ exec: String?, in path: String) -> String? {
        guard let exec, !exec.isEmpty else { return nil }
        let installed = exec.hasPrefix("/") ? exec : "\(path)/\(exec)"
        // A new build takes the place of the installed program.
        if let development = getenv("APUS_UI_DIR").map({ String(cString: $0) }),
           !development.isEmpty {
            let candidate = "\(development)/\(installed.split(separator: "/").last ?? "")"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        return access(installed, X_OK) == 0 ? installed : nil
    }

    /// "key = value" lines, without the comments and the empty lines.
    static func parse(_ text: String) -> [String: String] {
        var settings: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let statement = line.trimmed
            guard !statement.hasPrefix("#"), let separator = statement.firstIndex(of: "=") else {
                continue
            }
            let key = statement[..<separator].trimmed
            let value = statement[statement.index(after: separator)...].trimmed
            if !key.isEmpty { settings[key] = value }
        }
        return settings
    }

    /// The whole of a small file, as text.
    static func contents(of path: String) -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, 4096) }
            guard count > 0 else { break }
            bytes.append(contentsOf: chunk[0..<count])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Where `apus-gpu` keeps the build of Zink that the compositor draws
    /// with. See packages/apus-zink and docs/gpu.md.
    private static let zinkDirectory = "/usr/lib/apus-zink"

    /// The environment that an app gets.
    ///
    /// It is the compositor's, which carries WAYLAND_DISPLAY and the rest of
    /// the session, without the two things that belong to the compositor
    /// alone.
    ///
    /// `apus-gpu` puts the compositor on a build of Zink with a check taken
    /// out of it, by naming the driver and putting its directory first on
    /// the library path. Both of those cross `exec`, so every app the
    /// compositor started drew with that driver as well. It is not a driver
    /// for everything on the system: the check it does without is one that
    /// the four shaders of the shell happen not to need, and a program whose
    /// shaders do need it reads from a descriptor with nothing bound. An app
    /// gets the drivers of the distribution instead.
    static func environment() -> [String] {
        var result: [String] = []
        var usedZink = false
        var entry = environ
        while let text = entry.pointee {
            defer { entry += 1 }
            let line = String(cString: text)
            guard line.hasPrefix("LD_LIBRARY_PATH=") else {
                result.append(line)
                continue
            }
            // The directory goes; anything else on the path stays.
            let value = line.dropFirst("LD_LIBRARY_PATH=".count)
            let kept = value.split(separator: ":", omittingEmptySubsequences: true)
                .filter { $0 != zinkDirectory }
            usedZink = kept.count != value.split(separator: ":",
                                                 omittingEmptySubsequences: true).count
            if !kept.isEmpty { result.append("LD_LIBRARY_PATH=" + kept.joined(separator: ":")) }
        }
        // Only a compositor that apus-gpu started names the driver, so only
        // then is the name one that the compositor put there.
        if usedZink { result.removeAll { $0 == "MESA_LOADER_DRIVER_OVERRIDE=zink" } }
        return result
    }

    /// Starts the program of a bundle. The child gets the environment of the
    /// compositor, without what belongs to the compositor alone.
    @discardableResult
    static func start(_ bundle: AppBundle) -> pid_t? {
        guard let program = bundle.arguments.first else { return nil }
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = bundle.arguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        // The app gets a session of its own, so that Ctrl+C on the console of
        // the compositor does not stop it, and the signals of the compositor
        // stay with the compositor.
        var attributes = posix_spawnattr_t()
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = AppCatalog.spawnSetSID | AppCatalog.resetSignals(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var envp: [UnsafeMutablePointer<CChar>?] = AppCatalog.environment().map { strdup($0) }
        envp.append(nil)
        defer { envp.forEach { free($0) } }
        let result = posix_spawn(&pid, program, nil, &attributes, argv, envp)
        guard result == 0 else {
            log("compositor: can't start \(bundle.command): \(String(cString: strerror(result)))")
            return nil
        }
        log("APP-STARTED \(bundle.id) pid \(pid)")
        return pid
    }
}

private extension StringProtocol {
    /// The text without the spaces and tabs at its ends.
    var trimmed: String {
        String(drop { $0 == " " || $0 == "\t" }.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
    }
}
