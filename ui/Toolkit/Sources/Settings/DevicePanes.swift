import Toolkit

// The panes of the devices and the software: the screen, the keys, the
// network, and the apps that Summon lists.
//
// The shell reads the screen and the keyboard from its environment when it
// starts, so the two panes keep a draft. Save writes it for the next start,
// and the notice offers that start.

struct DisplayPane: View {
    let store: SettingsStore

    private var draft: ShellSettings { store.displayDraft }
    private var running: ShellSettings { store.snapshot.running }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
            Card { screens }
            SectionTitle(title: "When the shell starts")
            Card { choices }
            SaveBar(isChanged: store.displayIsChanged,
                    isWaiting: store.snapshot.saved.display != running.display,
                    save: store.saveDisplay, revert: store.revertDisplay)
        }
    }

    @ViewBuilder
    private var screens: some View {
        if store.snapshot.screens.isEmpty {
            SettingRow("Screen", value: "No screen is connected")
        }
        ForEach(store.snapshot.screens) { screen in
            SettingRow(screen.id, value: screen.mode.replacing("x", with: " × "),
                       detail: "Connected")
            RowDivider()
        }
        SettingRow("Drawn by", value: running.renderer == .gpu ? "The GPU" : "The CPU",
                   detail: running.scale.map { "\(Parse.number($0)) pixels to the point" }
                       ?? "The scale that the screen asks for")
    }

    @ViewBuilder
    private var choices: some View {
        SettingRow("Renderer", detail: "The GPU falls back to the CPU on a machine that has none") {
            Choice(options: [(ShellSettings.Renderer.cpu, "CPU"), (.gpu, "GPU")],
                   selected: draft.renderer) { value in store.setDisplay { $0.renderer = value } }
        }
        RowDivider()
        SettingRow("Surfaces", detail: "Lines and flat colours, or shadows and blur") {
            Choice(options: [(ShellSettings.Look.automatic, "Automatic"), (.cpu, "Flat"),
                             (.gpu, "Depth")],
                   selected: draft.look) { value in store.setDisplay { $0.look = value } }
        }
        RowDivider()
        SettingRow("Scale", detail: "Pixels to a point. Automatic reads the size of the screen.") {
            Choice(options: [(nil as Double?, "Automatic"), (1, "1×"), (1.5, "1.5×"), (2, "2×")],
                   selected: draft.scale) { value in store.setDisplay { $0.scale = value } }
        }
    }
}

/// The foot of a pane with a draft: what state it is in, and Save.
struct SaveBar: View {
    let isChanged: Bool
    /// Saved, and the shell has not started with it yet.
    let isWaiting: Bool
    let save: () -> Void
    let revert: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isChanged {
                Pill(text: "Not saved", color: Ink.accent)
            } else if isWaiting {
                Pill(text: "Saved", color: Ink.warning)
                Text("The shell starts with these next time")
                    .font(Font(size: 11))
                    .foregroundColor(Ink.dimText)
            } else {
                Text("The shell runs with these now")
                    .font(Font(size: 11))
                    .foregroundColor(Ink.dimText)
            }
            Spacer()
            PushButton("Revert", isEnabled: isChanged, action: revert)
            PushButton("Save", style: .primary, isEnabled: isChanged, action: save)
        }
        .padding(.horizontal, 4)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
    }
}

struct KeyboardPane: View {
    let store: SettingsStore
    let height: Double

    private var draft: ShellSettings { store.keyboardDraft }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
            Card { options }
            SectionTitle(title: "Layout")
            list
            SaveBar(isChanged: store.keyboardIsChanged,
                    isWaiting: store.snapshot.saved.keyboard != store.snapshot.running.keyboard,
                    save: store.saveKeyboard, revert: store.revertKeyboard)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var options: some View {
        SettingRow("Caps Lock", detail: "What the key does") {
            Choice(options: [("", "Caps Lock"), ("ctrl:nocaps", "Control"),
                             ("caps:escape", "Escape")],
                   selected: draft.capsLock) { value in store.setKeyboard { $0.setCapsLock(value) } }
        }
        RowDivider()
        SettingRow("Swap Alt and Super", detail: "For a keyboard of a Mac") {
            Switch(isOn: draft.has("altwin:swap_alt_win")) {
                store.setKeyboard { $0.set("altwin:swap_alt_win", !$0.has("altwin:swap_alt_win")) }
            }
        }
        RowDivider()
        SettingRow("Right Alt is Compose", detail: "Then two keys write one letter: ' and e write é") {
            Switch(isOn: draft.has("compose:ralt")) {
                store.setKeyboard { $0.set("compose:ralt", !$0.has("compose:ralt")) }
            }
        }
        RowDivider()
        SettingRow("Try the keys", detail: "With the layout that runs now") {
            TextField(text: store.text(of: .tryKeys), placeholder: "Click and type",
                      isEditing: store.editing == .tryKeys, width: 200) {
                store.beginEditing(.tryKeys)
            }
        }
    }

    private var list: some View {
        let layouts = KeyboardLayout.all
        let chosen = KeyboardLayout.matching(draft)
        let running = KeyboardLayout.matching(store.snapshot.running)
        let hasKeyboard = store.focus == .pane && store.editing == nil
        return ScrollView(offset: store.listOffset(.keyboard), reveal: store.reveal(for: .keyboard)) {
            VStack(spacing: 0) {
                ForEach(0..<layouts.count) { index in
                    ListRow(title: layouts[index].name, detail: layouts[index].id,
                            isSelected: index == store.layoutSelection, hasKeyboard: hasKeyboard,
                            action: { store.selectLayout(at: index) }) {
                        HStack(spacing: 10) {
                            if layouts[index] == running {
                                Text("NOW")
                                    .font(Font(size: 9, weight: .bold))
                                    .foregroundColor(Ink.faintText)
                            }
                            if layouts[index] == chosen {
                                Tick().fill(Ink.accent).frame(width: 11, height: 9)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Ink.card))
        .clipped()
    }
}

struct NetworkPane: View {
    let store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
            if store.snapshot.interfaces.isEmpty {
                Card { SettingRow("No network device", value: "") }
            }
            ForEach(store.snapshot.interfaces) { interface in
                InterfaceCard(interface: interface) { store.renew(interface.id) }
            }
            SectionTitle(title: "Name servers")
            Card {
                if store.snapshot.nameServers.isEmpty {
                    SettingRow("None", value: "", detail: "systemd-resolved has no server to ask")
                }
                ForEach(Array(store.snapshot.nameServers.enumerated()), id: \.offset) { server in
                    if server.offset > 0 { RowDivider() }
                    SettingRow(server.offset == 0 ? "First" : "Then", value: server.element)
                }
            }
        }
    }
}

struct InterfaceCard: View {
    let interface: NetworkInterface
    let renew: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(interface.isConnected ? Ink.good : Ink.dimText)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(interface.id)
                        .font(Font(size: 15, weight: .bold))
                        .foregroundColor(Ink.text)
                    Text(kind)
                        .font(Font(size: 11))
                        .foregroundColor(Ink.dimText)
                }
                Spacer()
                Pill(text: state, color: interface.isConnected ? Ink.good : Ink.warning)
                PushButton("Renew", action: renew)
            }
            .padding(.horizontal, Metrics.rowPadding)
            .frame(height: 60)
            .frame(maxWidth: .infinity)
            RowDivider()
            SettingRow("Address", value: interface.ipv4.first ?? "None")
            ForEach(Array(interface.ipv6.prefix(2).enumerated()), id: \.offset) { address in
                RowDivider()
                SettingRow(address.offset == 0 ? "IPv6" : "", value: address.element)
            }
            if !interface.gateway.isEmpty {
                RowDivider()
                SettingRow("Router", value: interface.gateway)
            }
            RowDivider()
            SettingRow("Hardware", value: interface.hardwareAddress.uppercased())
        }
    }

    private var kind: String {
        let what = switch interface.kind {
        case .wired: "Wired"
        case .wireless: "Wireless"
        case .other: "Network"
        }
        return interface.speed > 0
            ? "\(what), \(interface.speed >= 1000 ? "\(interface.speed / 1000) Gb/s" : "\(interface.speed) Mb/s")"
            : what
    }

    private var state: String {
        switch interface.state {
        case "up": "Connected"
        case "down": "Off"
        case "dormant", "lowerlayerdown": "No cable"
        default: interface.state.isEmpty ? "Unknown" : interface.state
        }
    }
}

struct AppsPane: View {
    let store: SettingsStore
    let height: Double

    var body: some View {
        let apps = store.snapshot.apps
        let bundles = apps.filter { $0.source == .bundle }.count
        let hidden = apps.filter { !$0.isShown }.count
        return VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
            Card {
                SettingRow("In /Applications", value: "\(bundles)",
                           detail: "The apps of Apus. Summon always lists them.")
                RowDivider()
                SettingRow("From packages", value: "\(apps.count - bundles)",
                           detail: hidden > 0 ? "\(hidden) hidden from Summon"
                                              : "pacman installs these with a desktop entry")
            }
            SectionTitle(title: "Every app")
            list(apps)
            Text("Space shows or hides the selected app. Summon reads the list each time it opens.")
                .font(Font(size: 11))
                .foregroundColor(Ink.faintText)
                .padding(.leading, 4)
        }
        .frame(maxHeight: .infinity)
    }

    private func list(_ apps: [AppInfo]) -> some View {
        let hasKeyboard = store.focus == .pane
        return ScrollView(offset: store.listOffset(.apps), reveal: store.reveal(for: .apps)) {
            VStack(spacing: 0) {
                ForEach(0..<apps.count) { index in
                    ListRow(mark: apps[index].color, title: apps[index].name,
                            detail: apps[index].id, isSelected: index == store.appSelection,
                            hasKeyboard: hasKeyboard,
                            action: { store.selectApp(at: index) }) {
                        HStack(spacing: 12) {
                            Text(apps[index].source == .bundle ? "APUS" : "PACKAGE")
                                .font(Font(size: 9, weight: .bold))
                                .foregroundColor(Ink.faintText)
                            Switch(isOn: apps[index].isShown,
                                   isEnabled: apps[index].source == .package) {
                                store.selectApp(at: index)
                                store.toggleShown(apps[index])
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Ink.card))
        .clipped()
    }
}

struct SoundPane: View {
    let store: SettingsStore

    private var sounds: SoundSettings { store.snapshot.sounds }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
            Card {
                SettingRow("System sounds",
                           detail: "A short sound for a message, an error, the charger and the bell") {
                    Switch(isOn: sounds.enabled) { store.setSounds { $0.enabled.toggle() } }
                }
                RowDivider()
                SettingRow("Loudness", detail: "Against the volume of the machine, which the volume keys set") {
                    Choice(options: [(0.25, "25%"), (0.5, "50%"), (0.75, "75%"), (1.0, "100%")],
                           selected: sounds.volume) { value in store.setSounds { $0.volume = value } }
                }
                RowDivider()
                SettingRow("Try it", detail: "The sound of a message") {
                    PushButton("Play", isEnabled: sounds.enabled) { store.playSample() }
                }
            }
            Text("A change counts at once, in every app.")
                .font(Font(size: 11))
                .foregroundColor(Ink.faintText)
                .padding(.leading, 4)
        }
    }
}
