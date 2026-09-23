@testable import Files
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Render
import Toolkit

/// A disk for the tests: a few folders in memory, and one that may not be
/// read.
final class Disk: FileSystem {
    var folders: [String: [FileEntry]] = [
        "/": [
            FileEntry(name: "root", kind: .folder),
            FileEntry(name: "usr", kind: .folder),
            FileEntry(name: "tmp", kind: .folder),
            FileEntry(name: "Applications", kind: .folder),
            FileEntry(name: "bin", kind: .folder, isLink: true),
        ],
        "/root": [
            FileEntry(name: "notes.txt", kind: .file, size: 812),
            FileEntry(name: "Notes", kind: .folder),
            FileEntry(name: "apus.img", kind: .file, size: 3 << 30),
            FileEntry(name: ".bashrc", kind: .file, size: 51),
            FileEntry(name: "build.sh", kind: .program, size: 4200),
            FileEntry(name: "Pictures", kind: .folder),
            FileEntry(name: "old", kind: .brokenLink, isLink: true),
        ],
        "/root/Notes": [],
        "/root/Pictures": [FileEntry(name: ".thumbnails", kind: .folder)],
        "/usr": [FileEntry(name: "bin", kind: .folder), FileEntry(name: "lib", kind: .folder)],
        "/usr/bin": (0..<3000).map { FileEntry(name: "tool\($0)", kind: .program, size: 10_000) },
        "/tmp": [],
        "/Applications": [FileEntry(name: "Files.app", kind: .folder)],
    ]
    var unreadable: Set<String> = ["/usr/lib"]
    var lists: [String] = []

    var home: String { "/root" }

    func list(_ path: String) -> Listing {
        lists.append(path)
        if unreadable.contains(path) { return .failed("You may not read \(path)") }
        guard let entries = folders[path] else { return .failed("\(path) is not there") }
        return .entries(entries)
    }

    func isFolder(_ path: String) -> Bool { folders[path] != nil }
}

extension KeyEvent {
    static let up = KeyEvent(keysym: 0xFF52)
    static let down = KeyEvent(keysym: 0xFF54)
    static let left = KeyEvent(keysym: 0xFF51)
    static let right = KeyEvent(keysym: 0xFF53)
    static let enter = KeyEvent(keysym: 0xFF0D)
    static let escape = KeyEvent(keysym: 0xFF1B)
    static let backspace = KeyEvent(keysym: 0xFF08)
    static let end = KeyEvent(keysym: 0xFF57)

    static func letter(_ character: Character) -> KeyEvent {
        KeyEvent(keysym: character.unicodeScalars.first!.value, characters: String(character))
    }
}

/// Draws a view into pixels. When APUS_PREVIEWS names a folder, the
/// picture is also written there as a PPM, so that a person can look at
/// what the test drew without a VM: `APUS_PREVIEWS=/tmp/p make test-ui`.
@discardableResult
func preview(_ view: some View, width: Int, height: Int, name: String) -> [UInt32] {
    let list = ViewRenderer.displayList(for: view, in: Rect(x: 0, y: 0, width: width, height: height))
    var pixels = [UInt32](repeating: 0xFF000000, count: width * height)
    pixels.withUnsafeMutableBufferPointer { memory in
        SoftwareRenderer.render(list, into: Canvas(pixels: memory.baseAddress!, width: width,
                                                   height: height, stride: width))
    }
    if let folder = getenv("APUS_PREVIEWS").map({ String(cString: $0) }),
       let file = fopen("\(folder)/\(name).ppm", "wb") {
        defer { fclose(file) }
        let head = Array("P6\n\(width) \(height)\n255\n".utf8)
        fwrite(head, 1, head.count, file)
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 3)
        for pixel in pixels {
            bytes += [UInt8((pixel >> 16) & 0xFF), UInt8((pixel >> 8) & 0xFF), UInt8(pixel & 0xFF)]
        }
        fwrite(bytes, 1, bytes.count, file)
    }
    return pixels
}
