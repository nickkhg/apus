import Foundation

/// What the tool was asked to boot, and how to show it.
struct Options {
    enum Mode: String {
        /// The live image, plus a blank target disk, to test the installer.
        case live
        /// The target disk alone: what the installer wrote.
        case installed
    }

    enum Display {
        /// No graphics device. The serial console is the only interface.
        case none
        /// A graphics device in a macOS window, with a keyboard and a pointer.
        case window
        /// A graphics device with no window. The screen is read in the guest
        /// (see tests/screen.py), because Virtualization has no screenshot.
        case headless
    }

    var mode: Mode
    var display: Display
    /// The size of the target disk, in bytes.
    var targetSize: UInt64
    /// The size of the screen, in pixels.
    var screen: (width: Int, height: Int)

    static let usage = """
        usage: mydistro-vm live|installed

          live        the live image and a blank target disk
          installed   the disk that the installer wrote

        VM_GPU selects the display: unset (console only), window, or headless.
        TARGET_SIZE sets the size of the target disk (default 8G).
        VM_SCREEN sets the size of the screen, for example 1920x1200
        (default 1280x800; the pixel tests need that size).
        """

    static func parse(
        arguments: [String], environment: [String: String]
    ) throws(Failure) -> Options {
        let words = arguments.dropFirst()
        guard words.count <= 1 else { throw .usage }
        guard let mode = Mode(rawValue: words.first ?? "live") else { throw .usage }

        let display: Display
        switch environment["VM_GPU"] ?? "" {
        case "": display = .none
        case "window": display = .window
        case "headless": display = .headless
        default: throw .badDisplay
        }

        let size = environment["TARGET_SIZE"] ?? "8G"
        guard let targetSize = bytes(size) else { throw .badSize(size) }

        // The pixel tests read fixed positions, so the default stays the
        // size that tests/compositor.exp describes.
        let wanted = environment["VM_SCREEN"] ?? "1280x800"
        guard let screen = screenSize(wanted) else { throw .badScreen(wanted) }

        return Options(mode: mode, display: display, targetSize: targetSize, screen: screen)
    }

    /// A size as WIDTHxHEIGHT.
    private static func screenSize(_ text: String) -> (width: Int, height: Int)? {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
              width >= 640, height >= 480 else { return nil }
        return (width, height)
    }

    enum Failure: Error, CustomStringConvertible {
        case usage
        case badDisplay
        case badSize(String)
        case badScreen(String)

        var description: String {
            switch self {
            case .usage: Options.usage
            case .badDisplay: "VM_GPU must be empty, 'window' or 'headless'"
            case .badSize(let text): "TARGET_SIZE is not a size: \(text)"
            case .badScreen(let text):
                "VM_SCREEN must be WIDTHxHEIGHT, at least 640x480: \(text)"
            }
        }
    }

    /// A size with an optional K, M or G suffix, as bytes.
    private static func bytes(_ text: String) -> UInt64? {
        let units: [Character: UInt64] = ["K": 1 << 10, "M": 1 << 20, "G": 1 << 30]
        if let last = text.last, let unit = units[Character(last.uppercased())] {
            return UInt64(text.dropLast()).map { $0 * unit }
        }
        return UInt64(text)
    }
}
