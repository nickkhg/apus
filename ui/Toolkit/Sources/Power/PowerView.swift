import Render
import Toolkit

// The window of Power: where the power comes from, how much is left, and
// how much goes out now. A machine with no battery says so, and says why,
// since that is what a VM on a Mac is. A tile is 256 points across and
// draws something else (PowerTile).

/// The whole window.
public struct PowerView: View {
    let store: PowerStore
    let sizeClass: SizeClass

    public init(store: PowerStore, sizeClass: SizeClass) {
        self.store = store
        self.sizeClass = sizeClass
    }

    private var reading: PowerReading { store.reading }
    private var padding: Double { sizeClass == .large ? 32 : 20 }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Ink.mark)
                        .frame(width: 8, height: 8)
                    Text("Power")
                        .font(Font(size: 22, weight: .bold))
                        .foregroundColor(Ink.text)
                    Spacer()
                }
                Text("Where the power of this machine comes from")
                    .font(Font(size: 13))
                    .foregroundColor(Ink.dimText)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                switch reading.source {
                case .nothingReported:
                    NoSupplyCard(store: store, columns: sizeClass == .large ? 76 : 50)
                case .mains:
                    MainsCard(reading: reading)
                case .battery, .batteryOnMains:
                    BatteryCard(reading: reading, history: store.history)
                    ForEach(Array(reading.batteries.enumerated()), id: \.offset) { item in
                        BatteryDetails(battery: item.element, isOnly: reading.batteries.count == 1)
                            .padding(.top, 16)
                    }
                }
                if !reading.adapters.isEmpty {
                    SupplyList(title: "ADAPTERS", supplies: reading.adapters)
                        .padding(.top, 16)
                }
                if !reading.devices.isEmpty {
                    SupplyList(title: "DEVICES", supplies: reading.devices)
                        .padding(.top, 16)
                }
                Text("Read from /sys/class/power_supply every two seconds")
                    .font(Font(size: 11))
                    .foregroundColor(Ink.faintText)
                    .padding(.top, 20)
            }
            .padding(padding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.background)
        .clipped()
    }
}

/// A group on a panel with round corners.
struct Card<Content: View>: View {
    let vertical: Double
    let content: Content

    init(vertical: Double = 24, @ViewBuilder content: () -> Content) {
        self.vertical = vertical
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.horizontal, 24)
        .padding(.vertical, vertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Ink.card))
    }
}

/// The charge, the state, and the power that goes out or in.
struct BatteryCard: View {
    let reading: PowerReading
    let history: [Double]

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 24) {
                BatteryMark(percent: reading.capacity ?? 0)
                    .frame(width: 96, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    if let capacity = reading.capacity {
                        HStack(alignment: .bottom, spacing: 2) {
                            Text("\(Int(capacity.rounded()))")
                                .font(Font(size: 46, weight: .bold))
                                .foregroundColor(Ink.text)
                            Text("%")
                                .font(Font(size: 22))
                                .foregroundColor(Ink.dimText)
                                .padding(.bottom, 6)
                        }
                    }
                    Text(reading.state)
                        .font(Font(size: 13))
                        .foregroundColor(Ink.secondaryText)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(reading.watts.map(Words.watts) ?? "—")
                        .font(Font(size: 28, weight: .bold))
                        .foregroundColor(Ink.text)
                    Text(reading.isCharging ? "GOING IN" : reading.source == .battery ? "GOING OUT" : "NOW")
                        .font(Font(size: 10, weight: .bold))
                        .foregroundColor(Ink.dimText)
                }
            }
            if !history.isEmpty {
                Divider(thickness: 1)
                    .foregroundColor(Ink.divider)
                    .padding(.top, 20)
                History(values: history, height: 64)
                    .padding(.top, 16)
                Text("THE POWER OF THE LAST MINUTE")
                    .font(Font(size: 10, weight: .bold))
                    .foregroundColor(Ink.faintText)
                    .padding(.top, 8)
            }
        }
    }
}

/// A machine with an adapter and no battery.
struct MainsCard: View {
    let reading: PowerReading

    var body: some View {
        Card {
            HStack(spacing: 20) {
                PlugMark()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("On AC power")
                        .font(Font(size: 28, weight: .bold))
                        .foregroundColor(Ink.text)
                    Text("This machine has no battery. It runs from its adapter.")
                        .font(Font(size: 13))
                        .foregroundColor(Ink.secondaryText)
                }
                Spacer()
            }
        }
    }
}

/// The kernel names no supply at all. In a VM on a Mac, that is the
/// normal case, so it is a state of its own and not an error.
struct NoSupplyCard: View {
    let store: PowerStore
    /// How many characters a line of the text holds.
    let columns: Int

    var body: some View {
        Card {
            HStack(spacing: 20) {
                PlugMark()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No battery")
                        .font(Font(size: 28, weight: .bold))
                        .foregroundColor(Ink.text)
                    Text(store.machine == .appleVM ? "The Mac has the power"
                         : "The kernel names no battery and no adapter")
                        .font(Font(size: 13))
                        .foregroundColor(Ink.secondaryText)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines(store.noBatteryReason, columns: columns).enumerated()),
                        id: \.offset) { line in
                    Text(line.element)
                        .font(Font(size: 13))
                        .foregroundColor(Ink.dimText)
                }
            }
            .padding(.top, 20)
            Divider(thickness: 1)
                .foregroundColor(Ink.divider)
                .padding(.top, 20)
            row("Where Power looks", "/sys/class/power_supply")
            row("What it found", "Nothing")
            row("A battery that comes", "shows here within two seconds")
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(name)
                .font(Font(size: 12))
                .foregroundColor(Ink.dimText)
            Spacer(minLength: 12)
            Text(value)
                .font(Font(size: 12))
                .foregroundColor(Ink.secondaryText)
        }
        .frame(height: 34)
    }
}

/// The values of one battery, the ones that it gives.
struct BatteryDetails: View {
    let battery: PowerSupply
    let isOnly: Bool

    var body: some View {
        Card(vertical: 16) {
            Text(isOnly ? "BATTERY" : battery.name.uppercased())
                .font(Font(size: 10, weight: .bold))
                .foregroundColor(Ink.faintText)
                .padding(.bottom, 6)
            ForEach(Array(rows.enumerated()), id: \.offset) { item in
                if item.offset > 0 {
                    Divider(thickness: 1).foregroundColor(Ink.divider)
                }
                HStack(spacing: 12) {
                    Text(item.element.0)
                        .font(Font(size: 13))
                        .foregroundColor(Ink.secondaryText)
                    Spacer(minLength: 12)
                    Text(item.element.1)
                        .font(Font(size: 13))
                        .foregroundColor(Ink.text)
                }
                .frame(height: Metrics.row)
            }
        }
    }

    private var rows: [(String, String)] {
        var rows: [(String, String)] = []
        rows.append(("State", PowerView.words(for: battery.status)))
        if let energy = battery.energy, let full = battery.energyFull {
            rows.append(("Energy", "\(Words.wattHours(energy)) of \(Words.wattHours(full))"))
        }
        if let health = battery.health {
            rows.append(("Health", "\(Words.percent(health)) of what it held when new"))
        }
        if let volts = battery.volts { rows.append(("Voltage", Words.volts(volts))) }
        if let cycles = battery.cycles { rows.append(("Cycles", "\(cycles)")) }
        if let temperature = battery.temperature {
            rows.append(("Temperature", "\(Words.tenths(temperature)) °C"))
        }
        let name = [battery.manufacturer, battery.model, battery.technology]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        if !name.isEmpty { rows.append(("Model", name)) }
        return rows
    }
}

extension PowerView {
    static func words(for status: PowerSupply.Status) -> String {
        switch status {
        case .charging: "Charging"
        case .discharging: "Discharging"
        case .full: "Full"
        case .notCharging: "Not charging"
        case .unknown: "Unknown"
        }
    }
}

/// The adapters, or the batteries of devices: a name and whether it is on.
struct SupplyList: View {
    let title: String
    let supplies: [PowerSupply]

    var body: some View {
        Card(vertical: 16) {
            Text(title)
                .font(Font(size: 10, weight: .bold))
                .foregroundColor(Ink.faintText)
                .padding(.bottom, 6)
            ForEach(Array(supplies.enumerated()), id: \.offset) { item in
                if item.offset > 0 {
                    Divider(thickness: 1).foregroundColor(Ink.divider)
                }
                HStack(spacing: 12) {
                    Text(item.element.model.isEmpty ? item.element.name : item.element.model)
                        .font(Font(size: 13))
                        .foregroundColor(Ink.secondaryText)
                    Text(kind(item.element))
                        .font(Font(size: 11))
                        .foregroundColor(Ink.dimText)
                    Spacer(minLength: 12)
                    Pill(text: state(item.element), color: color(item.element))
                }
                .frame(height: Metrics.row)
            }
        }
    }

    private func kind(_ supply: PowerSupply) -> String {
        switch supply.kind {
        case .battery: "Battery"
        case .mains: "Adapter"
        case .usb: "USB"
        case .other(let name): name
        }
    }

    private func state(_ supply: PowerSupply) -> String {
        if supply.kind == .battery {
            return supply.capacity.map(Words.percent) ?? PowerView.words(for: supply.status)
        }
        return supply.isOnline ? "Connected" : "Not connected"
    }

    private func color(_ supply: PowerSupply) -> Color {
        if supply.kind == .battery { return Ink.charge(supply.capacity ?? 100) }
        return supply.isOnline ? Ink.good : Ink.dimText
    }
}

/// A word in a small box of its colour.
struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(Font(size: 9, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.14)))
    }
}

/// The readings so far, as a row of bars, each as tall as its part of the
/// largest. The newest is on the right.
struct History: View {
    let values: [Double]
    let height: Double

    var body: some View {
        let top = max(values.max() ?? 1, 0.1)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { sample in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Ink.flow)
                    .frame(width: 6, height: max(2, sample.element / top * height))
            }
            Spacer()
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }
}

/// A battery on its side, filled as far as it is charged.
struct BatteryMark: View {
    let percent: Double

    var body: some View {
        HStack(spacing: 2) {
            ChargeBar(part: percent / 100, color: Ink.charge(percent))
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Ink.secondaryText, lineWidth: 2)
                )
            RoundedRectangle(cornerRadius: 2)
                .fill(Ink.secondaryText)
                .frame(width: 5, height: 16)
        }
    }
}

/// The part of a battery that is charged. It needs the width that it is
/// given, which a view cannot read, so it draws itself.
struct ChargeBar: View {
    typealias Body = Never
    let part: Double
    let color: Color

    func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        nodes.append(ChargeNode(part: part, color: color))
    }
}

final class ChargeNode: LayoutNode {
    let part: Double
    let color: Color

    init(part: Double, color: Color) {
        self.part = part
        self.color = color
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        Size(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        let width = max(0, min(1, part)) * frame.width
        guard width > 1 else { return }
        var path = Path()
        path.addRoundedRectangle(x: frame.x, y: frame.y, width: width, height: frame.height,
                                 radius: 4)
        pass.list.append(.path(path.scaled(by: pass.scale), color: color.premultiplied))
    }
}

/// A plug: a body with two pins, for a machine that runs from the wall.
struct PlugMark: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1).fill(Ink.secondaryText).frame(width: 4, height: 10)
                RoundedRectangle(cornerRadius: 1).fill(Ink.secondaryText).frame(width: 4, height: 10)
            }
            RoundedRectangle(cornerRadius: 5)
                .fill(Ink.secondaryText)
                .frame(width: 26, height: 18)
            RoundedRectangle(cornerRadius: 1)
                .fill(Ink.secondaryText)
                .frame(width: 4, height: 12)
        }
    }
}

/// A text broken into lines of at most `columns` characters, at spaces. A
/// `Text` is one line, and a sentence of a card needs a few.
func lines(_ text: String, columns: Int) -> [String] {
    var result: [String] = []
    var line = ""
    for word in text.split(separator: " ") {
        if !line.isEmpty, line.count + 1 + word.count > columns {
            result.append(line)
            line = ""
        }
        line += line.isEmpty ? String(word) : " " + word
    }
    if !line.isEmpty { result.append(line) }
    return result
}
