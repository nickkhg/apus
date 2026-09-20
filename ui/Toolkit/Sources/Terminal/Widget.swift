import Render
import Toolkit

// The terminal as a tile.
//
// A tile is 256 points across, which holds about 30 characters of the grid.
// A grid that narrow is not a terminal that a person can work in, so the
// tile does not draw one. It states what the shell is doing and shows the
// last lines of it, which is what a person wants from the corner of an eye.

/// What the tile of a terminal shows.
public struct TerminalWidget: View {
    /// The screen of the shell, for the last lines.
    let screen: Screen
    /// The title of the window. The shell sets it, so it usually names the
    /// directory and the command.
    let title: String
    /// How many lines of the grid the tile has room for.
    let lineCount: Int

    public init(screen: Screen, title: String, lineCount: Int = 8) {
        self.screen = screen
        self.title = title
        self.lineCount = lineCount
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            Divider(thickness: 1)
                .foregroundColor(TerminalWidget.divider)
                .padding(.vertical, 10)
            Text("LAST LINES")
                .font(Font(size: 9, weight: .bold))
                .foregroundColor(TerminalWidget.faint)
                .padding(.bottom, 6)
            ForEach(Array(lastLines.enumerated()), id: \.offset) { line in
                Text(line.element)
                    .font(.monospaced(size: 10))
                    .foregroundColor(TerminalWidget.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
            Divider(thickness: 1)
                .foregroundColor(TerminalWidget.divider)
                .padding(.bottom, 8)
            Text(title.isEmpty ? "bash" : title)
                .font(Font(size: 10))
                .foregroundColor(TerminalWidget.dim)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: Palette.background))
        .clipped()
    }

    private var head: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(TerminalWidget.mark)
                .frame(width: 8, height: 8)
            Text("Terminal")
                .font(Font(size: 13, weight: .bold))
                .foregroundColor(TerminalWidget.title)
            Spacer()
        }
    }

    /// The last lines of the grid that have something in them. The work is
    /// at the bottom of a terminal, so the tile reads from there upwards.
    var lastLines: [String] {
        var result: [String] = []
        for row in screen.lines.reversed() {
            let text = TerminalWidget.text(of: row)
            if text.isEmpty, result.isEmpty { continue }   // the empty end
            result.append(text)
            if result.count == lineCount { break }
        }
        return result.reversed()
    }

    /// One row of the grid as text, without the spaces at the end of it.
    static func text(of row: [Cell]) -> String {
        var text = String(row.map(\.character))
        while text.last == " " { text.removeLast() }
        return text
    }

    // The colours of the terminal, so that the tile and the window match.
    static let mark = Color(hex: 0x3BB273)
    static let title = Color(hex: 0xF2F5F4)
    static let body = Color(hex: 0xA3AEB4)
    static let dim = Color(hex: 0x6C777D)
    static let faint = Color(hex: 0x444E54)
    static let divider = Color(hex: 0x232A31)
}
