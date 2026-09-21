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

/// One app bundle.
struct AppBundle {
    /// The id of the app. A window of the app gives the same id in
    /// xdg_toplevel.set_app_id.
    let id: String
    let name: String
    /// The colour of the icon, 0xRRGGBB.
    let color: UInt32
    /// The program to start, as an absolute path.
    let command: String

    /// What the dock shows.
    var entry: AppEntry { AppEntry(id: id, name: name, color: Color(hex: color)) }
}

enum AppCatalog {
    /// Where the bundles are.
    static let directory = "/Applications"
    /// POSIX_SPAWN_SETSID of glibc. The C headers give it to the
    /// preprocessor only, so Swift does not see it.
    private static let spawnSetSID: Int32 = 0x80

    /// The bundles in `directory`, by name.
    ///
    /// With APUS_UI_DIR set (`make test-dev` and `make demo-dev` set it),
    /// a program of that directory takes the place of the installed one with
    /// the same name. Then a bundle starts the new build.
    static func bundles(in directory: String = AppCatalog.directory) -> [AppBundle] {
        guard let handle = opendir(directory) else {
            debug("no \(directory): the dock stays empty")
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
        return AppBundle(id: id, name: name, color: color, command: command)
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
    private static func contents(of path: String) -> String? {
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

    /// Starts the program of a bundle. The child gets the environment of the
    /// compositor, which has WAYLAND_DISPLAY in it.
    @discardableResult
    static func start(_ bundle: AppBundle) -> pid_t? {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(bundle.command), nil]
        defer { argv.forEach { free($0) } }
        // The app gets a session of its own, so that Ctrl+C on the console of
        // the compositor does not stop it.
        var attributes = posix_spawnattr_t()
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(AppCatalog.spawnSetSID))
        defer { posix_spawnattr_destroy(&attributes) }
        let result = posix_spawn(&pid, bundle.command, nil, &attributes, argv, environ)
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
