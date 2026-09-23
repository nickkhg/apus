import Render
@testable import Power
import Testing
import Toolkit

// What Power makes of the files of /sys/class/power_supply, on a laptop and
// on a machine with none. The files are in Supplies.swift.

@Suite("Power")
struct PowerTests {
    @Test("A battery that counts in energy")
    func energyBattery() {
        let battery = PowerSupply.parse(Sample.energyBattery, name: "BAT0")
        #expect(battery.kind == .battery)
        #expect(battery.status == .discharging)
        #expect(battery.watts == 7.4)
        #expect(battery.energy == 41.2 && battery.energyFull == 52.6)
        #expect(battery.capacity == 78)
        #expect(battery.cycles == 212)
        #expect(Int(battery.health!.rounded()) == 92)
        // 41.2 Wh at 7.4 W is 5.57 hours.
        #expect(Words.duration(battery.secondsLeft!) == "5 h 34 min")
        #expect(battery.secondsToFull == nil)
    }

    @Test("A battery that counts in charge, with a current below zero")
    func chargeBattery() {
        let battery = PowerSupply.parse(Sample.chargeBattery, name: "BAT1")
        #expect(battery.energy == 24 && battery.energyFull == 48, "charge times the voltage")
        #expect(battery.watts == 18)
        #expect(battery.capacity == 50, "from the energy, with no capacity given")
        #expect(battery.temperature == 31.2)
        #expect(Words.duration(battery.secondsToFull!) == "1 h 20 min")
        #expect(battery.health == nil)
    }

    @Test("A laptop on its battery, with the adapter out")
    func onBattery() {
        let reading = PowerReading([PowerSupply.parse(Sample.energyBattery, name: "BAT0"),
                                    PowerSupply.parse(Sample.unplugged, name: "AC"),
                                    PowerSupply.parse(Sample.mouse, name: "hidpp_battery_0")])
        #expect(reading.source == .battery)
        #expect(reading.batteries.count == 1)
        #expect(reading.devices.map(\.model) == ["MX Master 3"], "a mouse is not the machine")
        #expect(reading.state == "On battery · 5 h 34 min left")
        #expect(Int(reading.capacity!.rounded()) == 78)
    }

    @Test("A laptop that charges")
    func charging() {
        let reading = PowerReading([PowerSupply.parse(Sample.chargeBattery, name: "BAT1"),
                                    PowerSupply.parse(Sample.adapter, name: "AC"),
                                    PowerSupply.parse(Sample.usbPort, name: "usb")])
        #expect(reading.source == .batteryOnMains)
        #expect(reading.isCharging)
        #expect(reading.state == "Charging · 1 h 20 min to full")
        #expect(reading.adapters.count == 2)
    }

    @Test("A desktop has an adapter and no battery")
    func desktop() {
        let reading = PowerReading([PowerSupply.parse(Sample.adapter, name: "AC")])
        #expect(reading.source == .mains)
        #expect(reading.state == "On AC power")
        #expect(reading.watts == nil)
    }

    @Test("A VM on a Mac names nothing, and Power says why")
    func nothing() {
        let store = PowerStore(source: Supplies([], machine: .appleVM))
        #expect(store.reading.source == .nothingReported)
        #expect(store.reading.state == "No battery")
        #expect(store.noBatteryReason.contains("virtual machine on a Mac"))
        #expect(MachineKind.from(detectVirt: "apple\n") == .appleVM)
        #expect(MachineKind.from(detectVirt: "kvm\n") == .virtualMachine("kvm"))
        #expect(MachineKind.from(detectVirt: "none\n") == .unknown)
        #expect(MachineKind.from(detectVirt: "container-other\n") == .container,
                "what the builder container of Apus says")
        #expect(MachineKind.from(detectVirt: "") == .unknown, "no systemd-detect-virt")
    }

    @Test("The power is read every two seconds, and the bars keep the last thirty")
    func history() {
        let supplies = Supplies([("BAT0", Sample.energyBattery)])
        let store = PowerStore(source: supplies)
        #expect(store.history == [7.4])
        store.tick(now: 1)
        store.tick(now: 2)
        #expect(store.history.count == 2, "the second tick is too soon")
        for second in 3...80 { store.tick(now: Double(second)) }
        #expect(store.history.count == PowerStore.historyLength)
        supplies.files = []
        store.tick(now: 100)
        #expect(store.reading.source == .nothingReported, "a battery that goes away goes")
    }

    @Test("The charger and a low battery make a sound, and a low battery only once")
    func sounds() {
        /// The battery of the samples at a charge, in percent of its 52.6 Wh.
        func battery(_ percent: Double) -> String {
            Sample.energyBattery.replacing("POWER_SUPPLY_ENERGY_NOW=41200000",
                                           with: "POWER_SUPPLY_ENERGY_NOW=\(Int(percent * 526_000))")
        }
        let supplies = Supplies([("AC", Sample.unplugged), ("BAT0", battery(15))])
        let store = PowerStore(source: supplies)
        var played: [String] = []
        store.play = { played.append($0.rawValue) }
        var now = 0.0
        func read(_ files: [(name: String, uevent: String)]) {
            supplies.files = files
            now += 2
            store.tick(now: now)
        }

        read([("AC", Sample.unplugged), ("BAT0", battery(11))])
        #expect(played.isEmpty)
        read([("AC", Sample.unplugged), ("BAT0", battery(9))])
        read([("AC", Sample.unplugged), ("BAT0", battery(8))])
        #expect(played == ["battery-low"], "once, not at each reading")
        read([("AC", Sample.adapter), ("BAT0", battery(8))])
        #expect(played == ["battery-low", "power-plug"])
        read([("AC", Sample.unplugged), ("BAT0", battery(8))])
        #expect(played == ["battery-low", "power-plug", "power-unplug", "battery-low"],
                "the charger made the low sound ready again")
        read([("AC", Sample.unplugged), ("BAT0", battery(11))])
        read([("AC", Sample.unplugged), ("BAT0", battery(9))])
        #expect(played.count == 4, "11 % is under the level that makes it ready again")
        read([])
        read([("AC", Sample.adapter), ("BAT0", battery(9))])
        #expect(played.count == 4, "a driver that comes and goes is no charger")
    }

    @Test("A duration and a power in the words of a person")
    func words() {
        #expect(Words.duration(20) == "under a minute")
        #expect(Words.duration(45 * 60) == "45 min")
        #expect(Words.duration(3 * 3600 + 5 * 60) == "3 h 05 min")
        #expect(Words.watts(7.43) == "7.4 W")
        #expect(Words.watts(12.6) == "13 W")
        #expect(lines("one two three four", columns: 9) == ["one two", "three", "four"])
    }

    @Test("Every state draws at each size, and the previews are written")
    func everyStateDraws() {
        let machines: [(String, Supplies)] = [
            ("vm", Supplies([], machine: .appleVM)),
            ("desktop", Supplies([("AC", Sample.adapter)])),
            ("battery", Supplies([("BAT0", Sample.energyBattery), ("AC", Sample.unplugged),
                                  ("mouse", Sample.mouse)])),
            ("charging", Supplies([("BAT1", Sample.chargeBattery), ("AC", Sample.adapter)])),
        ]
        for (name, supplies) in machines {
            let store = PowerStore(source: supplies)
            for second in 2...24 where second % 2 == 0 { store.tick(now: Double(second)) }
            let large = preview(PowerView(store: store, sizeClass: .large), width: 1184,
                                height: 744, name: "power-\(name)-large")
            #expect(large.contains { $0 != large[0] })
            preview(PowerView(store: store, sizeClass: .compact), width: 560, height: 744,
                    name: "power-\(name)-compact")
            let tile = preview(PowerTile(store: store), width: 256, height: 256,
                               name: "power-\(name)-tile")
            #expect(tile.contains { $0 != tile[0] })
        }
    }
}
