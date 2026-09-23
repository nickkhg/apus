import Files
import Glibc

/// The folders of this machine, as Files reads them. Nothing on this system
/// uses Foundation, so this is the C library.
final class Disk: FileSystem {
    let home: String

    init() {
        if let value = getenv("HOME"), value.pointee != 0 {
            home = String(cString: value)
        } else if let user = getpwuid(getuid()), let directory = user.pointee.pw_dir {
            home = String(cString: directory)
        } else {
            home = "/"
        }
    }

    func isFolder(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    func list(_ path: String) -> Listing {
        guard let folder = opendir(path) else { return .failed(problem(path)) }
        defer { closedir(folder) }
        var entries: [FileEntry] = []
        while let item = readdir(folder) {
            let name = withUnsafeBytes(of: item.pointee.d_name) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard name != ".", name != ".." else { continue }
            entries.append(entry(name, in: path))
        }
        return .entries(entries)
    }

    /// One name of a folder. `lstat` says whether it is a link, and `stat`
    /// says what the link points to.
    private func entry(_ name: String, in folder: String) -> FileEntry {
        let path = folder == "/" ? "/" + name : folder + "/" + name
        var own = stat()
        guard lstat(path, &own) == 0 else { return FileEntry(name: name, kind: .special) }
        let isLink = (own.st_mode & S_IFMT) == S_IFLNK
        var info = own
        if isLink, stat(path, &info) != 0 {
            return FileEntry(name: name, kind: .brokenLink, isLink: true)
        }
        let kind: FileEntry.Kind = switch info.st_mode & S_IFMT {
        case S_IFDIR: .folder
        case S_IFREG: info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0 ? .program : .file
        default: .special
        }
        return FileEntry(name: name, kind: kind, size: UInt64(max(0, info.st_size)),
                         isLink: isLink)
    }

    /// Why a folder does not open, in words.
    private func problem(_ path: String) -> String {
        switch errno {
        case EACCES, EPERM: "You may not read \(path)"
        case ENOENT: "\(path) is not there any more"
        case ENOTDIR: "\(path) is not a folder"
        default: "\(path) cannot be read: \(String(cString: strerror(errno)))"
        }
    }
}
