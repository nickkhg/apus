import Render
import Toolkit

// What the system monitor draws. It has two user interfaces: one for a tile
// of 256 points across, and one for a window with room.
//
// The tile is not the window made smaller. It keeps the one number that a
// person wants from the corner of an eye — how busy the processor is — and
// drops everything that needs reading.

/// The colours of the app. They are the colours of the design, written here
/// because an app does not link the user interface of the system.
enum Ink {
    static let background = Color(hex: 0x0E1114)
    static let panel = Color(hex: 0x171C21)
    static let divider = Color(hex: 0x232A31)
    static let mark = Color(hex: 0x49C7C7)
    static let title = Color(hex: 0xF2F5F4)
    static let body = Color(hex: 0xA3AEB4)
    static let dim = Color(hex: 0x6C777D)
    static let faint = Color(hex: 0x444E54)
    static let memory = Color(hex: 0x7C6CF0)
    static let disk = Color(hex: 0xE0A458)
}

/// The tile: 256 points across, and 256 long.
struct MonitorTile: View {
    let readings: Readings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            Number(value: Int((readings.processor * 100).rounded()), unit: "%", size: 46)
                .padding(.top, 12)
            Text("CPU")
                .font(Font(size: 10, weight: .bold))
                .foregroundColor(Ink.dim)
                .padding(.top, 4)
            History(values: readings.history, colour: Ink.mark, height: 56)
                .padding(.top, 8)
            Divider(thickness: 1)
                .foregroundColor(Ink.divider)
                .padding(.top, 2)
            Meter(name: "MEMORY", value: humanSize(readings.memoryUsed)
                    + " / " + humanSize(readings.memoryTotal),
                  part: readings.memoryPart, colour: Ink.memory)
                .padding(.top, 14)
            Meter(name: "DISK", value: humanSize(readings.diskUsed)
                    + " / " + humanSize(readings.diskTotal),
                  part: readings.diskPart, colour: Ink.disk)
                .padding(.top, 14)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.background)
        .clipped()
    }

    private var head: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Ink.mark)
                .frame(width: 8, height: 8)
            Text("System")
                .font(Font(size: 13, weight: .bold))
                .foregroundColor(Ink.title)
            Spacer()
        }
    }
}

/// The window: the same numbers with room around them.
struct MonitorWindow: View {
    let readings: Readings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("System")
                .font(Font(size: 22, weight: .bold))
                .foregroundColor(Ink.title)
            Text("What this machine is doing now")
                .font(Font(size: 13))
                .foregroundColor(Ink.dim)
                .padding(.top, 4)
            card
                .padding(.top, 24)
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.background)
        .clipped()
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 24) {
                Number(value: Int((readings.processor * 100).rounded()), unit: "%", size: 64)
                VStack(alignment: .leading, spacing: 0) {
                    Text("PROCESSOR")
                        .font(Font(size: 10, weight: .bold))
                        .foregroundColor(Ink.dim)
                    Text("of the machine is busy")
                        .font(Font(size: 13))
                        .foregroundColor(Ink.body)
                        .padding(.top, 4)
                }
                Spacer()
            }
            History(values: readings.history, colour: Ink.mark, height: 96)
                .padding(.top, 20)
            Divider(thickness: 1)
                .foregroundColor(Ink.divider)
                .padding(.top, 20)
            Meter(name: "MEMORY", value: humanSize(readings.memoryUsed)
                    + " of " + humanSize(readings.memoryTotal),
                  part: readings.memoryPart, colour: Ink.memory)
                .padding(.top, 20)
            Meter(name: "DISK", value: humanSize(readings.diskUsed)
                    + " of " + humanSize(readings.diskTotal),
                  part: readings.diskPart, colour: Ink.disk)
                .padding(.top, 20)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Ink.panel)
        )
    }
}

/// A large number with a small unit after it.
struct Number: View {
    let value: Int
    let unit: String
    let size: Double

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            Text("\(value)")
                .font(Font(size: size, weight: .bold))
                .foregroundColor(Ink.title)
            Text(unit)
                .font(Font(size: size * 0.5))
                .foregroundColor(Ink.dim)
                .padding(.bottom, size * 0.12)
        }
    }
}

/// The readings so far, as a row of bars. The newest is on the right.
struct History: View {
    let values: [Double]
    let colour: Color
    let height: Double

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { sample in
                RoundedRectangle(cornerRadius: 1)
                    .fill(colour)
                    // A bar of nothing is still drawn, so that the row does
                    // not change shape when the machine goes quiet.
                    .frame(width: 8, height: max(2, sample.element * height))
            }
            Spacer()
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }
}

/// A name, a value, and a bar of how much is in use.
struct Meter: View {
    let name: String
    let value: String
    let part: Double
    let colour: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(name)
                    .font(Font(size: 10, weight: .bold))
                    .foregroundColor(Ink.dim)
                Spacer()
                Text(value)
                    .font(Font(size: 11))
                    .foregroundColor(Ink.body)
            }
            Bar(part: part, colour: colour)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One bar: the whole width in a dark colour, and the part in use over it.
struct Bar: View {
    let part: Double
    let colour: Color

    var body: some View {
        GeometryBar(part: part, colour: colour)
            .frame(height: 6)
            .frame(maxWidth: .infinity)
    }
}

/// Draws the two parts of a bar. It needs the width that it is given, which
/// a view cannot read, so it draws itself.
struct GeometryBar: View {
    public typealias Body = Never
    let part: Double
    let colour: Color

    func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        nodes.append(BarNode(part: part, colour: colour))
    }
}

final class BarNode: LayoutNode {
    let part: Double
    let colour: Color

    init(part: Double, colour: Color) {
        self.part = part
        self.colour = colour
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        Size(width: proposal.width ?? 0, height: proposal.height ?? 6)
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        let radius = frame.height / 2
        var track = Path()
        track.addRoundedRectangle(x: frame.x, y: frame.y, width: frame.width,
                                  height: frame.height, radius: radius)
        pass.list.append(.path(track.scaled(by: pass.scale), color: Ink.divider.premultiplied))
        let width = max(0, min(1, part)) * frame.width
        guard width > 1 else { return }
        var value = Path()
        value.addRoundedRectangle(x: frame.x, y: frame.y, width: width,
                                  height: frame.height, radius: radius)
        pass.list.append(.path(value.scaled(by: pass.scale), color: colour.premultiplied))
    }
}
