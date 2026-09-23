import Glibc
import Notes

/// The folder of the notes on this machine: ~/Notes. Nothing on this system
/// uses Foundation, so this is the C library.
final class Folder: NotesFolder {
    let path: String
    let place: String

    init() {
        var home = "/root"
        if let value = getenv("HOME"), value.pointee != 0 {
            home = String(cString: value)
        } else if let user = getpwuid(getuid()), let directory = user.pointee.pw_dir {
            home = String(cString: directory)
        }
        path = (home == "/" ? "" : home) + "/Notes"
        place = "~/Notes"
    }

    func prepare() -> String? {
        guard mkdir(path, 0o755) == 0 || errno == EEXIST else {
            return "\(place) cannot be made: \(String(cString: strerror(errno)))"
        }
        return nil
    }

    func list() -> [NoteFile] {
        guard let folder = opendir(path) else { return [] }
        defer { closedir(folder) }
        var files: [NoteFile] = []
        while let item = readdir(folder) {
            let name = withUnsafeBytes(of: item.pointee.d_name) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            var info = stat()
            guard stat(file(name), &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let modified = Double(info.st_mtim.tv_sec) + Double(info.st_mtim.tv_nsec) / 1_000_000_000
            files.append(NoteFile(name: name, modified: modified))
        }
        return files
    }

    func read(_ name: String) -> String? {
        let fd = open(file(name), O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Glibc.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            bytes += buffer[0..<count]
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The text goes to a file beside the note, which then takes its name,
    /// so that a reader sees the old note or the new one and never half.
    func write(_ name: String, _ text: String) -> Saved {
        let target = file(name)
        let temporary = file(".\(name).notes-\(getpid())")
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return .failed("\(place)/\(name) cannot be written") }
        let bytes = Array(text.utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes {
                Glibc.write(fd, $0.baseAddress! + written, $0.count - written)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                close(fd)
                unlink(temporary)
                return .failed("\(place)/\(name) cannot be written: the disk may be full")
            }
            written += count
        }
        fsync(fd)
        close(fd)
        guard rename(temporary, target) == 0 else {
            unlink(temporary)
            return .failed("\(place)/\(name) cannot be replaced")
        }
        var info = stat()
        guard stat(target, &info) == 0 else { return .saved(modified: 0) }
        return .saved(modified: Double(info.st_mtim.tv_sec)
                      + Double(info.st_mtim.tv_nsec) / 1_000_000_000)
    }

    func remove(_ name: String) -> String? {
        unlink(file(name)) == 0 ? nil : "\(place)/\(name) cannot be removed"
    }

    private func file(_ name: String) -> String { path + "/" + name }
}
