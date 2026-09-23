import Render
@testable import Settings
import Testing
import Toolkit

// What Settings does with the keys and the clicks, and what it asks of the
// machine. The machine is the one in Machine.swift.

@Suite("Settings")
struct StoreTests {
    @Test("The arrows walk the sidebar, and Enter gives the keys to the pane")
    func sidebarKeys() {
        let store = SettingsStore(system: Machine())
        #expect(store.pane == .about && store.focus == .sidebar)
        store.key(.down)
        store.key(.down)
        #expect(store.pane == .password)
        store.key(.up)
        #expect(store.pane == .time)
        store.key(.enter)
        #expect(store.focus == .pane)
        store.key(.escape)
        #expect(store.focus == .sidebar)
    }

    @Test("A new host name is typed, checked and set")
    func hostName() {
        let machine = Machine()
        let store = SettingsStore(system: machine)
        store.beginEditing(.hostName)
        for _ in 0..<4 { store.key(.backspace) }
        store.type("swift 1")
        store.key(.enter)
        #expect(machine.calls.isEmpty, "a space is not allowed in a host name")
        #expect(store.notice(for: .about)?.kind == .failure)
        #expect(store.editing == .hostName, "the field stays open to be put right")
        store.key(.backspace)
        store.key(.backspace)
        store.type("-1")
        store.key(.enter)
        #expect(machine.calls == ["hostname swift-1"])
        #expect(store.snapshot.about.hostName == "swift-1")
        #expect(store.editing == nil)
    }

    @Test("Escape leaves a field without a change")
    func escapeCancels() {
        let machine = Machine()
        let store = SettingsStore(system: machine)
        store.beginEditing(.hostName)
        store.type("xyz")
        store.key(.escape)
        #expect(store.text(of: .hostName) == "apus")
        #expect(machine.calls.isEmpty)
    }

    @Test("Typing in Date & Time narrows the zones, and Enter sets one")
    func zoneSearch() {
        let machine = Machine()
        let store = SettingsStore(system: machine)
        store.select(.time)
        #expect(store.zones[store.zoneSelection].id == "Europe/Berlin",
                "the zone in use is selected")
        // A letter from the sidebar goes to the list at once.
        store.type("tok")
        #expect(store.focus == .pane)
        #expect(store.zones.map(\.id) == ["Asia/Tokyo"])
        store.key(.enter)
        #expect(machine.calls == ["zone Asia/Tokyo"])
        #expect(store.snapshot.time.zone == "Asia/Tokyo")
        store.key(.escape)
        #expect(store.zoneQuery.isEmpty)
        #expect(store.zones[store.zoneSelection].id == "Asia/Tokyo")
    }

    @Test("The two passwords must agree")
    func passwords() {
        let machine = Machine()
        let store = SettingsStore(system: machine)
        store.select(.password)
        store.beginEditing(.password)
        store.type("hunter2")
        #expect(store.text(of: .password) == "•••••••", "a password never shows")
        store.key(.enter)
        #expect(store.editing == .confirmation)
        store.type("hunter3")
        store.key(.enter)
        #expect(machine.calls.isEmpty)
        #expect(store.notice(for: .password)?.kind == .failure)
        #expect(store.editing == .password, "both start again")
        store.type("hunter2")
        store.key(.tab)
        store.type("hunter2")
        store.key(.enter)
        #expect(machine.calls == ["password hunter2"])
        #expect(store.snapshot.password == .set)
        #expect(store.passwordDraft.isEmpty && store.confirmationDraft.isEmpty,
                "the password is not kept")
    }

    @Test("A draft of the display is saved with the keyboard that was saved")
    func displayDraft() {
        let machine = Machine()
        machine.snapshot.saved = ShellSettings(renderer: .gpu, layout: "de")
        let store = SettingsStore(system: machine)
        #expect(!store.displayIsChanged)
        store.setDisplay { $0.scale = 2 }
        store.setKeyboard { $0.layout = "fr" }
        #expect(store.displayIsChanged && store.keyboardIsChanged)
        store.saveDisplay()
        #expect(machine.snapshot.saved == ShellSettings(renderer: .gpu, scale: 2, layout: "de"),
                "the keyboard is not saved with the display")
        #expect(!store.displayIsChanged)
        #expect(store.keyboardIsChanged)
        #expect(store.notice(for: .display)?.action == .restartShell)
        store.revertKeyboard()
        #expect(!store.keyboardIsChanged)
    }

    @Test("The keyboard list chooses a layout, and the choice waits to be saved")
    func keyboardList() {
        let machine = Machine()
        let store = SettingsStore(system: machine)
        store.select(.keyboard)
        store.key(.enter)
        #expect(store.focus == .pane)
        store.key(.down)
        store.key(.down)
        store.key(.enter)
        #expect(store.keyboardDraft.layout == "us" && store.keyboardDraft.variant == "dvorak")
        store.setKeyboard { $0.setCapsLock("caps:escape") }
        store.setKeyboard { $0.setCapsLock("ctrl:nocaps") }
        #expect(store.keyboardDraft.options == ["ctrl:nocaps"], "the Caps Lock choices exclude one another")
        store.saveKeyboard()
        #expect(machine.calls.last?.contains("XKB_DEFAULT_VARIANT=dvorak") == true)
    }

    @Test("Space hides an app of a package, and an app of Apus stays")
    func apps() {
        let machine = Machine()
        let store = SettingsStore(system: machine)
        store.select(.apps)
        store.key(.enter)
        store.key(.space)
        #expect(machine.calls.isEmpty)
        #expect(store.notice(for: .apps)?.kind == .information)
        store.key(.down)
        store.key(.down)
        store.key(.space)
        #expect(machine.calls == ["shown chromium false"])
        #expect(store.snapshot.apps[2].isShown == false)
    }

    @Test("Power asks twice, and forgets after five seconds")
    func power() {
        let machine = Machine()
        let store = SettingsStore(system: machine)
        store.tick(now: 100)
        store.press(.powerOff)
        #expect(store.armed == .powerOff)
        #expect(machine.calls.isEmpty)
        store.tick(now: 106)
        #expect(store.armed == nil)
        store.press(.powerOff)
        store.tick(now: 107)
        store.press(.powerOff)
        #expect(machine.calls == ["poweroff"])
    }

    @Test("A failure is said on the pane, in words")
    func failure() {
        let machine = Machine()
        machine.outcome = .failed("timedatectl said no")
        let store = SettingsStore(system: machine)
        store.setTimeZone("Asia/Tokyo")
        #expect(store.notice(for: .time) == Notice(kind: .failure, text: "timedatectl said no"))
        #expect(store.snapshot.time.zone == "Europe/Berlin")
    }

    @Test("A click on a line of the sidebar opens its pane")
    func clickTheSidebar() {
        let store = SettingsStore(system: Machine())
        let host = ViewHost()
        let view = SettingsView(store: store, sizeClass: .large, height: 744)
        let rect = Rect(x: 0, y: 0, width: 1184, height: 744)
        _ = host.displayList(for: view, in: rect)
        // The groups start under the head of 52 points; Network is the
        // sixth line, in the second group.
        host.pointerMoved(to: 60, y: 52 + 34 + 3 * 34 + 34 + 2 * 34 + 17)
        host.pointerButton(pressed: true)
        host.pointerButton(pressed: false)
        #expect(store.pane == .network)
    }

    @Test("Every pane draws, at each size")
    func everyPaneDraws() {
        let store = SettingsStore(system: Machine())
        for pane in Pane.allCases {
            store.select(pane)
            for (width, height) in [(1184, 744), (560, 744)] {
                let view = SettingsView(store: store, sizeClass: SizeClass.of(Proposal(
                    width: Double(width), height: Double(height))), height: Double(height))
                let pass = ViewRenderer.render(view, in: Rect(x: 0, y: 0, width: width,
                                                              height: height))
                #expect(!pass.list.isEmpty)
                #expect(pass.keyRegions.count == 1)
            }
        }
        let tile = ViewRenderer.render(SettingsTile(store: store),
                                       in: Rect(x: 0, y: 0, width: 256, height: 256))
        #expect(!tile.list.isEmpty)
    }
}
