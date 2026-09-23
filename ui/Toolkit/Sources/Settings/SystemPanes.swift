import Render
import Toolkit

// The panes of the system: this machine and its name, the clock, the
// password of root, and the power.

struct AboutPane: View {
    let store: SettingsStore

    private var about: About { store.snapshot.about }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
            identity
            Card { name }
            SectionTitle(title: "This machine")
            Card { details }
        }
    }

    private var identity: some View {
        HStack(spacing: 16) {
            Text("A")
                .font(Font(size: 28, weight: .bold))
                .foregroundColor(Ink.accent)
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 14).fill(Ink.accentSurface))
            VStack(alignment: .leading, spacing: 4) {
                Text(about.system)
                    .font(Font(size: 20, weight: .bold))
                    .foregroundColor(Ink.text)
                Text([about.build.isEmpty ? "" : "Build \(about.build)", about.architecture]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Font(size: 12))
                    .foregroundColor(Ink.dimText)
            }
            Spacer()
            Pill(text: about.isLive ? "Live system" : "Installed",
                 color: about.isLive ? Ink.warning : Ink.good)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Ink.card))
    }

    private var name: some View {
        SettingRow("Name", detail: "What this machine calls itself on the network") {
            HStack(spacing: 8) {
                TextField(text: store.text(of: .hostName), placeholder: "apus",
                          isEditing: store.editing == .hostName, width: 180) {
                    store.beginEditing(.hostName)
                }
                if store.editing == .hostName {
                    PushButton("Save", style: .primary) { store.setHostName(store.hostNameDraft) }
                }
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        SettingRow("System", value: about.system)
        RowDivider()
        SettingRow("Kernel", value: about.kernel)
        RowDivider()
        SettingRow("Processor", value: about.processors == 1 ? "1 core" : "\(about.processors) cores")
        RowDivider()
        SettingRow("Memory", value: humanSize(about.memory))
        RowDivider()
        SettingRow("Disk", detail: "\(humanSize(about.diskTotal > about.diskUsed ? about.diskTotal - about.diskUsed : 0)) free") {
            HStack(spacing: 10) {
                Meter(part: about.diskTotal > 0 ? Double(about.diskUsed) / Double(about.diskTotal) : 0,
                      color: Color(hex: 0xE0A458))
                    .frame(width: 96, height: 6)
                ValueText("\(humanSize(about.diskUsed)) of \(humanSize(about.diskTotal))")
            }
        }
        RowDivider()
        SettingRow("Running for", value: duration(about.uptime))
        RowDivider()
        SettingRow("Installed", value: about.isLive ? "Not yet: this is the live system"
                                                    : (about.installed ?? "Unknown"))
        if !about.virtualization.isEmpty {
            RowDivider()
            SettingRow("Runs on", value: about.virtualization == "apple"
                ? "A virtual machine on a Mac" : "A virtual machine (\(about.virtualization))")
        }
        RowDivider()
        SettingRow("Machine ID", value: String(about.machineID.prefix(16)))
    }
}

struct TimePane: View {
    let store: SettingsStore
    let height: Double

    private var time: TimeSettings { store.snapshot.time }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
            clock
            Card {
                SettingRow("Set the time from the network", detail: syncDetail) {
                    Switch(isOn: time.networkTime) { store.setNetworkTime(!time.networkTime) }
                }
            }
            SectionTitle(title: "Time zone")
            ZoneList(store: store, height: height)
        }
        .frame(maxHeight: .infinity)
    }

    private var syncDetail: String {
        guard time.networkTime else { return "The clock keeps its own time" }
        return time.synchronized ? "The clock agrees with a time server"
                                 : "Waiting for an answer from a time server"
    }

    private var clock: some View {
        let reading = store.clock
        return HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 2) {
                    Text(reading.time)
                        .font(Font(size: 40, weight: .bold))
                        .foregroundColor(Ink.text)
                    Text(reading.seconds)
                        .font(Font(size: 18))
                        .foregroundColor(Ink.dimText)
                        .padding(.bottom, 6)
                }
                Text(reading.date)
                    .font(Font(size: 13))
                    .foregroundColor(Ink.secondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(TimeZoneEntry(id: time.zone).city)
                    .font(Font(size: 15, weight: .bold))
                    .foregroundColor(Ink.text)
                Text("\(reading.abbreviation) · \(reading.offsetText)")
                    .font(Font(size: 11))
                    .foregroundColor(Ink.dimText)
            }
            .padding(.bottom, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Ink.card))
    }
}

/// The zones, with a query line over them. Typing narrows the list, as it
/// does in Summon.
struct ZoneList: View {
    let store: SettingsStore
    let height: Double

    var body: some View {
        let zones = store.zones
        let hasKeyboard = store.focus == .pane && store.pane == .time
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .stroke(hasKeyboard ? Ink.accent : Ink.dimText, lineWidth: 1.5)
                    .frame(width: 11, height: 11)
                if store.zoneQuery.isEmpty {
                    Text(hasKeyboard ? "Type a place to find its zone" : "Click here and type a place")
                        .font(Font(size: 13))
                        .foregroundColor(Ink.dimText)
                } else {
                    Text(store.zoneQuery)
                        .font(Font(size: 13))
                        .foregroundColor(Ink.text)
                }
                if hasKeyboard {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Ink.accent)
                        .frame(width: 2, height: 16)
                }
                Spacer()
                Text(zones.count == 1 ? "1 zone" : "\(zones.count) zones")
                    .font(Font(size: 11))
                    .foregroundColor(Ink.faintText)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(Color.clear.onTapGesture { store.focus(.pane) })
            Divider(thickness: 1).foregroundColor(Ink.divider)
            if zones.isEmpty {
                Text("No zone matches \(store.zoneQuery)")
                    .font(Font(size: 13))
                    .foregroundColor(Ink.dimText)
                    .frame(height: 64)
                Spacer()
            } else {
                ScrollView(offset: store.listOffset(.time), reveal: store.reveal(for: .time)) {
                    VisibleRows(count: zones.count, offset: store.listOffsets[.time] ?? 0,
                                viewport: height) { index in
                        ListRow(title: zones[index].city, detail: zones[index].region,
                                isSelected: index == store.zoneSelection,
                                hasKeyboard: hasKeyboard,
                                action: { store.selectZone(at: index) }) {
                            if zones[index].id == store.snapshot.time.zone {
                                Tick().fill(Ink.accent).frame(width: 11, height: 9)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Ink.card))
        .clipped()
    }
}

/// The rows of a long list that can show, with room above and below for
/// the others. Every row is `Metrics.listRow` tall, so the list knows where
/// each one is without laying it out.
struct VisibleRows<Row: View>: View {
    let count: Int
    /// How far the list is scrolled.
    let offset: Double
    /// The most of the list that can show at once.
    let viewport: Double
    let row: (Int) -> Row

    init(count: Int, offset: Double, viewport: Double, @ViewBuilder row: @escaping (Int) -> Row) {
        self.count = count
        self.offset = offset
        self.viewport = viewport
        self.row = row
    }

    var body: some View {
        // A few rows more at each end, so that a scroll between two frames
        // never shows a gap.
        let first = max(0, min(count, Int(offset / Metrics.listRow) - 4))
        let last = max(first, min(count, Int((offset + viewport) / Metrics.listRow) + 4))
        return VStack(spacing: 0) {
            Color.clear.frame(height: Double(first) * Metrics.listRow)
            ForEach(first..<last) { index in row(index) }
            Color.clear.frame(height: Double(count - last) * Metrics.listRow)
        }
    }
}

struct PasswordPane: View {
    let store: SettingsStore

    private var state: PasswordState { store.snapshot.password }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
            status
            SectionTitle(title: state == .none ? "Give root a password" : "A new password")
            Card { fields }
            Text("Tab moves between the two. Enter goes on, and Escape clears them.")
                .font(Font(size: 11))
                .foregroundColor(Ink.faintText)
                .padding(.leading, 4)
        }
    }

    private var status: some View {
        let (title, detail, color, word): (String, String, Color, String) = switch state {
        case .none: ("root has no password",
                     "Anyone at the screen or the console of this machine is root.",
                     Ink.warning, "Open")
        case .set: ("root has a password",
                    "The console asks for it before it lets anyone in.", Ink.good, "Protected")
        case .locked: ("root is locked",
                       "No password opens the account. A key for ssh still does.",
                       Ink.secondaryText, "Locked")
        case .unknown: ("The password cannot be read",
                        "Settings could not read /etc/shadow.", Ink.dimText, "Unknown")
        }
        return HStack(spacing: 14) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Font(size: 15, weight: .bold))
                    .foregroundColor(Ink.text)
                Text(detail)
                    .font(Font(size: 12))
                    .foregroundColor(Ink.dimText)
            }
            Spacer()
            Pill(text: word, color: color)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Ink.card))
    }

    @ViewBuilder
    private var fields: some View {
        SettingRow("New password") {
            TextField(text: store.text(of: .password), placeholder: "Click to type",
                      isEditing: store.editing == .password) { store.beginEditing(.password) }
        }
        RowDivider()
        SettingRow("Type it again") {
            TextField(text: store.text(of: .confirmation), placeholder: "",
                      isEditing: store.editing == .confirmation) {
                store.beginEditing(.confirmation)
            }
        }
        RowDivider()
        HStack(spacing: 8) {
            Spacer()
            if state == .set {
                PushButton("Remove the password", style: .danger) { store.removePassword() }
            }
            PushButton("Set the password", style: .primary,
                       isEnabled: !store.passwordDraft.isEmpty && !store.confirmationDraft.isEmpty) {
                store.setPassword()
            }
        }
        .padding(.horizontal, Metrics.rowPadding)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
    }
}

struct PowerPane: View {
    let store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
            Card {
                SettingRow("Running for", value: duration(store.snapshot.about.uptime))
                RowDivider()
                SettingRow("Load", value: load,
                           detail: "Processes waiting to run, over 1, 5 and 15 minutes")
            }
            SectionTitle(title: "Start again or stop")
            Card {
                action(.restartShell, title: "Restart the shell",
                       detail: store.snapshot.shellIsService
                           ? "Every app closes, and the shell comes back in a few seconds"
                           : "The shell was started by hand, so systemd cannot start it again",
                       button: "Restart", style: .normal, isEnabled: store.snapshot.shellIsService)
                RowDivider()
                action(.restartMachine, title: "Restart the machine",
                       detail: "Everything stops, and the machine starts again",
                       button: "Restart", style: .normal, isEnabled: true)
                RowDivider()
                action(.powerOff, title: "Shut down",
                       detail: "The machine stops. Nothing is kept that was not saved.",
                       button: "Shut down", style: .danger, isEnabled: true)
            }
            Text("Each one asks for a second click, within five seconds.")
                .font(Font(size: 11))
                .foregroundColor(Ink.faintText)
                .padding(.leading, 4)
        }
    }

    private var load: String {
        store.snapshot.load.prefix(3).map { value in
            let hundredths = Int((value * 100).rounded())
            return "\(hundredths / 100).\(twoDigits(hundredths % 100))"
        }.joined(separator: "  ")
    }

    private func action(_ action: SettingsStore.PowerAction, title: String, detail: String,
                        button: String, style: PushButton.Style,
                        isEnabled: Bool) -> some View {
        SettingRow(title, detail: detail) {
            PushButton(store.armed == action ? "Click again" : button,
                       style: store.armed == action ? .danger : style,
                       isEnabled: isEnabled) {
                store.press(action)
            }
        }
    }
}

/// A bar of how much is in use: the whole width dark, and the part in use
/// over it. It needs the width it is given, which a view cannot read, so
/// it draws itself.
struct Meter: View {
    typealias Body = Never
    let part: Double
    let color: Color

    func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        nodes.append(MeterNode(part: part, color: color))
    }
}

final class MeterNode: LayoutNode {
    let part: Double
    let color: Color

    init(part: Double, color: Color) {
        self.part = part
        self.color = color
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
        value.addRoundedRectangle(x: frame.x, y: frame.y, width: max(width, frame.height),
                                  height: frame.height, radius: radius)
        pass.list.append(.path(value.scaled(by: pass.scale), color: color.premultiplied))
    }
}
