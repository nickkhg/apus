import Toolkit

// What Settings is doing: the pane that is open, what a person has typed,
// and what came of the last change. The views read it and call it; they
// keep only how the pointer lights them.
//
// It holds the keys as well. The toolkit has no focus, so the app says
// which part has the keyboard — the sidebar or the pane — and every key
// goes through `key(_:)`. The accent marks the part that has it.

/// A message on a pane: what came of a change.
public struct Notice: Sendable, Equatable {
    public enum Kind: Sendable { case done, information, warning, failure }

    public var kind: Kind
    public var text: String
    /// A control on the notice that does the next step.
    public var action: Action?

    public enum Action: Sendable, Equatable {
        /// The change waits for the shell to start again.
        case restartShell
    }

    public init(kind: Kind, text: String, action: Action? = nil) {
        self.kind = kind
        self.text = text
        self.action = action
    }
}

public final class SettingsStore {
    /// Which part of the window reads the keys.
    public enum Focus: Sendable { case sidebar, pane }

    /// A place that takes text.
    public enum Field: Sendable { case hostName, password, confirmation, tryKeys }

    /// A change that stops the shell or the machine, and so asks twice.
    public enum PowerAction: Sendable { case restartShell, restartMachine, powerOff }

    let system: SettingsSystem
    /// Called after anything that the window shows changed.
    public var changed: () -> Void = {}

    public private(set) var snapshot: Snapshot
    public private(set) var clock: ClockReading

    public private(set) var pane = Pane.about
    public private(set) var focus = Focus.sidebar
    public private(set) var editing: Field?

    var hostNameDraft = ""
    var passwordDraft = ""
    var confirmationDraft = ""
    var tryText = ""

    public private(set) var zoneQuery = ""
    /// The line of the list that Enter takes, as an index into the list
    /// that the query leaves.
    public private(set) var zoneSelection = 0
    public private(set) var layoutSelection = 0
    public private(set) var appSelection = 0

    /// What a person has chosen and not yet saved.
    public private(set) var displayDraft: ShellSettings
    public private(set) var keyboardDraft: ShellSettings

    var notices: [Pane: Notice] = [:]
    public private(set) var armed: PowerAction?
    private var armedAt = 0.0
    /// Seconds, from the clock that `tick` gives.
    private var now = 0.0
    private var lastRead = 0.0

    /// How far each pane is scrolled, and each list in a pane.
    var offsets: [Pane: Double] = [:]
    var listOffsets: [Pane: Double] = [:]
    /// The keyboard moved a selection, so its list shows it in the next
    /// frame. See ScrollView(offset:reveal:).
    private var revealSelection = false

    /// How long a second press has to confirm a change of power.
    static let confirmTime = 5.0
    /// How often the snapshot is read again.
    static let readInterval = 3.0

    public init(system: SettingsSystem) {
        self.system = system
        let snapshot = system.read(zones: true)
        self.snapshot = snapshot
        self.clock = system.clock()
        displayDraft = snapshot.saved.display
        keyboardDraft = snapshot.saved.keyboard
        layoutSelection = KeyboardLayout.all.firstIndex {
            $0 == KeyboardLayout.matching(snapshot.saved)
        } ?? 0
        zoneSelection = zones.firstIndex { $0.id == snapshot.time.zone } ?? 0
        revealSelection = true
    }

    // MARK: - Time

    /// About once a second: the clock, a confirmation that ran out, and now
    /// and then everything else, since the machine changes on its own.
    public func tick(now: Double) {
        self.now = now
        clock = system.clock()
        if armed != nil, now - armedAt > SettingsStore.confirmTime { armed = nil }
        if now - lastRead >= SettingsStore.readInterval { reload() }
        changed()
    }

    /// Reads the machine again. A draft that nobody touched follows what
    /// the machine says.
    public func reload() {
        lastRead = now
        let old = snapshot
        var new = system.read(zones: false)
        new.time.zones = old.time.zones
        snapshot = new
        if displayDraft == old.saved.display { displayDraft = new.saved.display }
        if keyboardDraft == old.saved.keyboard { keyboardDraft = new.saved.keyboard }
        appSelection = min(appSelection, max(0, snapshot.apps.count - 1))
    }

    // MARK: - Where the keyboard is

    public func select(_ pane: Pane) {
        guard pane != self.pane else { return }
        self.pane = pane
        editing = nil
        armed = nil
        revealSelection = true
        changed()
    }

    public func focus(_ focus: Focus) {
        guard focus != self.focus else { return }
        self.focus = focus
        if focus == .sidebar { editing = nil }
        changed()
    }

    public func beginEditing(_ field: Field) {
        focus = .pane
        editing = field
        switch field {
        case .hostName: hostNameDraft = snapshot.about.hostName
        case .password:
            passwordDraft = ""
            confirmationDraft = ""
        case .confirmation: confirmationDraft = ""
        case .tryKeys: break
        }
        changed()
    }

    public func endEditing() {
        guard editing != nil else { return }
        editing = nil
        changed()
    }

    /// What a field shows.
    func text(of field: Field) -> String {
        switch field {
        case .hostName: editing == .hostName ? hostNameDraft : snapshot.about.hostName
        case .password: String(repeating: "•", count: passwordDraft.count)
        case .confirmation: String(repeating: "•", count: confirmationDraft.count)
        case .tryKeys: tryText
        }
    }

    // MARK: - The keys

    /// Every key of the window. It answers whether it used the key; it uses
    /// them all, because nothing under the app reads them.
    @discardableResult
    public func key(_ key: KeyEvent) -> Bool {
        guard key.isPressed else { return true }
        if let editing {
            edit(editing, with: key)
        } else if focus == .sidebar {
            sidebarKey(key)
        } else {
            paneKey(key)
        }
        changed()
        return true
    }

    private func sidebarKey(_ key: KeyEvent) {
        let panes = Pane.allCases
        let index = panes.firstIndex(of: pane) ?? 0
        switch key.named {
        case .up: select(panes[max(0, index - 1)])
        case .down: select(panes[min(panes.count - 1, index + 1)])
        case .home: select(panes[0])
        case .end: select(panes[panes.count - 1])
        case .enter, .right, .tab: focus = .pane
        default:
            // A letter goes to the list of the pane, so that typing a name
            // in Date & Time finds a zone at once.
            if pane == .time, typed(key) != nil {
                focus = .pane
                paneKey(key)
            }
        }
    }

    private func paneKey(_ key: KeyEvent) {
        switch pane {
        case .time: timeKey(key)
        case .keyboard:
            if listKey(key, count: KeyboardLayout.all.count, selection: &layoutSelection) {
                chooseLayout(KeyboardLayout.all[layoutSelection])
            }
        case .apps:
            if listKey(key, count: snapshot.apps.count, selection: &appSelection) {
                toggleShown(snapshot.apps[appSelection])
            }
        case .about where key.named == .enter: beginEditing(.hostName)
        case .password where key.named == .enter: beginEditing(.password)
        default: leaveKey(key)
        }
    }

    /// Escape, Tab and the left arrow give the keyboard back to the sidebar.
    private func leaveKey(_ key: KeyEvent) {
        switch key.named {
        case .escape, .left, .tab: focus = .sidebar
        default: break
        }
    }

    /// The arrows move a selection. Enter or Space answers true: do what
    /// the selected line says.
    private func listKey(_ key: KeyEvent, count: Int, selection: inout Int) -> Bool {
        guard count > 0 else {
            leaveKey(key)
            return false
        }
        switch key.named {
        case .up: selection = max(0, selection - 1)
        case .down: selection = min(count - 1, selection + 1)
        case .home: selection = 0
        case .end: selection = count - 1
        case .enter: return true
        default:
            if key.characters == " " { return true }
            leaveKey(key)
            return false
        }
        revealSelection = true
        return false
    }

    private func timeKey(_ key: KeyEvent) {
        let count = zones.count
        switch key.named {
        case .up where count > 0: zoneSelection = max(0, zoneSelection - 1)
        case .down where count > 0: zoneSelection = min(count - 1, zoneSelection + 1)
        case .home: zoneSelection = 0
        case .end: zoneSelection = max(0, count - 1)
        case .enter:
            if zones.indices.contains(zoneSelection) { setTimeZone(zones[zoneSelection].id) }
            return
        case .backspace:
            guard !zoneQuery.isEmpty else { return }
            zoneQuery.removeLast()
            zoneSelection = 0
            listOffsets[.time] = 0
        case .escape where !zoneQuery.isEmpty:
            zoneQuery = ""
            zoneSelection = zones.firstIndex { $0.id == snapshot.time.zone } ?? 0
        default:
            guard let character = typed(key) else { return leaveKey(key) }
            zoneQuery += character
            zoneSelection = 0
            listOffsets[.time] = 0
        }
        revealSelection = true
    }

    private func edit(_ field: Field, with key: KeyEvent) {
        switch key.named {
        case .escape:
            editing = nil
            if field == .password || field == .confirmation {
                passwordDraft = ""
                confirmationDraft = ""
            }
        case .enter: commit(field)
        case .tab:
            if field == .password { editing = .confirmation }
            if field == .confirmation { editing = .password }
        case .backspace:
            switch field {
            case .hostName: if !hostNameDraft.isEmpty { hostNameDraft.removeLast() }
            case .password: if !passwordDraft.isEmpty { passwordDraft.removeLast() }
            case .confirmation: if !confirmationDraft.isEmpty { confirmationDraft.removeLast() }
            case .tryKeys: if !tryText.isEmpty { tryText.removeLast() }
            }
        default:
            guard let character = typed(key) else { return }
            switch field {
            case .hostName: if hostNameDraft.count < 63 { hostNameDraft += character }
            case .password: passwordDraft += character
            case .confirmation: confirmationDraft += character
            case .tryKeys: tryText = String((tryText + character).suffix(48))
            }
        }
    }

    /// What a key writes into a line of text, or nil for a key that writes
    /// nothing, or that a chord with Control or Alt makes into a command.
    private func typed(_ key: KeyEvent) -> String? {
        guard !key.characters.isEmpty, !key.control, !key.alt else { return nil }
        return key.characters
    }

    private func commit(_ field: Field) {
        switch field {
        case .hostName: setHostName(hostNameDraft)
        case .password: editing = .confirmation
        case .confirmation: setPassword()
        case .tryKeys: editing = nil
        }
    }

    // MARK: - Lists

    /// The zones that the query leaves.
    public var zones: [TimeZoneEntry] {
        zoneQuery.isEmpty ? snapshot.time.zones
            : snapshot.time.zones.filter { Parse.matches($0, query: zoneQuery) }
    }

    /// The rows that a list shows once, in the frame after the keyboard
    /// moved its selection.
    func reveal(for pane: Pane) -> ClosedRange<Double>? {
        guard revealSelection, pane == self.pane else { return nil }
        let index = switch pane {
        case .time: zoneSelection
        case .keyboard: layoutSelection
        case .apps: appSelection
        default: -1
        }
        guard index >= 0 else { return nil }
        revealSelection = false
        let top = Double(index) * Metrics.listRow
        return top...(top + Metrics.listRow)
    }

    func offset(_ pane: Pane) -> Binding<Double> {
        Binding(get: { [unowned self] in offsets[pane] ?? 0 },
                set: { [unowned self] in
                    offsets[pane] = $0
                    changed()
                })
    }

    func listOffset(_ pane: Pane) -> Binding<Double> {
        Binding(get: { [unowned self] in listOffsets[pane] ?? 0 },
                set: { [unowned self] in
                    listOffsets[pane] = $0
                    changed()
                })
    }

    public func selectZone(at index: Int) {
        focus = .pane
        zoneSelection = index
        if zones.indices.contains(index) { setTimeZone(zones[index].id) }
        changed()
    }

    public func selectLayout(at index: Int) {
        focus = .pane
        layoutSelection = index
        chooseLayout(KeyboardLayout.all[index])
        changed()
    }

    public func selectApp(at index: Int) {
        focus = .pane
        appSelection = index
        changed()
    }

    // MARK: - Changes

    func notice(for pane: Pane) -> Notice? { notices[pane] }

    private func report(_ outcome: Outcome, on pane: Pane, action: Notice.Action? = nil) {
        switch outcome {
        case .done(let text): notices[pane] = Notice(kind: .done, text: text, action: action)
        case .failed(let text): notices[pane] = Notice(kind: .failure, text: text)
        }
        reload()
        // A new zone is a new time, and the pane shows it now rather than
        // at the next tick.
        clock = system.clock()
        changed()
    }

    public func setHostName(_ name: String) {
        if let problem = Parse.problem(withHostName: name) {
            notices[.about] = Notice(kind: .failure, text: problem)
            changed()
            return
        }
        editing = nil
        guard name != snapshot.about.hostName else { return changed() }
        report(system.setHostName(name), on: .about)
    }

    public func setTimeZone(_ zone: String) {
        guard zone != snapshot.time.zone else { return }
        report(system.setTimeZone(zone), on: .time)
    }

    public func setNetworkTime(_ on: Bool) {
        report(system.setNetworkTime(on), on: .time)
    }

    /// The password of the two fields, when they agree.
    public func setPassword() {
        guard !passwordDraft.isEmpty else {
            notices[.password] = Notice(kind: .failure, text: "Type a password first")
            editing = .password
            return changed()
        }
        guard passwordDraft == confirmationDraft else {
            notices[.password] = Notice(kind: .failure,
                                        text: "The two passwords are not the same. Type them again.")
            passwordDraft = ""
            confirmationDraft = ""
            editing = .password
            return changed()
        }
        let password = passwordDraft
        passwordDraft = ""
        confirmationDraft = ""
        editing = nil
        report(system.setPassword(password), on: .password)
    }

    public func removePassword() {
        editing = nil
        report(system.setPassword(nil), on: .password)
    }

    public func setDisplay(_ change: (inout ShellSettings) -> Void) {
        change(&displayDraft)
        notices[.display] = nil
        changed()
    }

    public func setKeyboard(_ change: (inout ShellSettings) -> Void) {
        change(&keyboardDraft)
        notices[.keyboard] = nil
        changed()
    }

    private func chooseLayout(_ layout: KeyboardLayout) {
        setKeyboard {
            $0.layout = layout.layout == "us" && layout.variant.isEmpty ? "" : layout.layout
            $0.variant = layout.variant
        }
    }

    /// The display has changes that are not saved.
    var displayIsChanged: Bool { displayDraft != snapshot.saved.display }
    var keyboardIsChanged: Bool { keyboardDraft != snapshot.saved.keyboard }

    public func saveDisplay() {
        var settings = snapshot.saved
        settings.renderer = displayDraft.renderer
        settings.look = displayDraft.look
        settings.scale = displayDraft.scale
        save(settings, on: .display)
    }

    public func saveKeyboard() {
        var settings = snapshot.saved
        settings.layout = keyboardDraft.layout
        settings.variant = keyboardDraft.variant
        settings.options = keyboardDraft.options
        save(settings, on: .keyboard)
    }

    public func revertDisplay() {
        displayDraft = snapshot.saved.display
        notices[.display] = nil
        changed()
    }

    public func revertKeyboard() {
        keyboardDraft = snapshot.saved.keyboard
        layoutSelection = KeyboardLayout.all.firstIndex {
            $0 == KeyboardLayout.matching(keyboardDraft)
        } ?? 0
        notices[.keyboard] = nil
        changed()
    }

    private func save(_ settings: ShellSettings, on pane: Pane) {
        let outcome = system.saveShellSettings(settings)
        if case .done = outcome, snapshot.shellIsService {
            report(outcome, on: pane, action: .restartShell)
        } else {
            report(outcome, on: pane)
        }
    }

    public func renew(_ interface: String) {
        report(system.renew(interface), on: .network)
    }

    public func toggleShown(_ app: AppInfo) {
        guard app.source == .package else {
            notices[.apps] = Notice(kind: .information,
                                    text: "\(app.name) is an app of Apus, and Summon always lists it")
            return changed()
        }
        report(system.setShown(app, !app.isShown), on: .apps)
    }

    /// A change to the sounds counts at once: there is nothing to start
    /// again. A sound then plays at the new loudness, so a person hears
    /// what they chose.
    public func setSounds(_ change: (inout SoundSettings) -> Void) {
        var settings = snapshot.sounds
        change(&settings)
        guard settings != snapshot.sounds else { return }
        let outcome = system.saveSounds(settings)
        guard case .done = outcome else { return report(outcome, on: .sound) }
        notices[.sound] = nil
        reload()
        if settings.enabled { system.play(.messageNewInstant) }
        changed()
    }

    /// Plays a sound, to hear how loud the sounds are.
    public func playSample() {
        system.play(.messageNewInstant)
    }

    /// The first press arms the change, and a second one within five
    /// seconds makes it. The machine does not stop on a stray click.
    public func press(_ action: PowerAction) {
        guard armed == action, now - armedAt <= SettingsStore.confirmTime else {
            armed = action
            armedAt = now
            return changed()
        }
        armed = nil
        switch action {
        case .restartShell: report(system.restartShell(), on: .power)
        case .restartMachine: report(system.restartMachine(), on: .power)
        case .powerOff: report(system.powerOff(), on: .power)
        }
    }

    /// The control of a notice.
    public func perform(_ action: Notice.Action, from pane: Pane) {
        switch action {
        case .restartShell: report(system.restartShell(), on: pane)
        }
    }
}
