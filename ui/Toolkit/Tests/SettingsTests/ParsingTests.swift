@testable import Settings
import Testing

// The files of the system, as Settings understands them.

@Suite("The files that Settings reads")
struct ParsingTests {
    @Test("os-release takes quotes off its values and skips comments")
    func osRelease() {
        let values = Parse.assignments("""
            # the release
            NAME="Apus"
            PRETTY_NAME='Apus'
            BUILD_ID=rolling
            """)
        #expect(values["NAME"] == "Apus")
        #expect(values["PRETTY_NAME"] == "Apus")
        #expect(values["BUILD_ID"] == "rolling")
        #expect(values.count == 3)
    }

    @Test("A drop-in gives the environment of the shell, and back again")
    func dropInRoundTrip() {
        let settings = ShellSettings(renderer: .gpu, look: .cpu, scale: 1.5, layout: "de",
                                     variant: "nodeadkeys",
                                     options: ["ctrl:nocaps", "altwin:swap_alt_win"])
        let text = Parse.dropIn(for: settings)
        #expect(text.contains("[Service]"))
        #expect(text.contains("Environment=APUS_SCALE=1.5"))
        #expect(text.contains("Environment=XKB_DEFAULT_OPTIONS=ctrl:nocaps,altwin:swap_alt_win"))
        #expect(Parse.shellSettings(Parse.unitEnvironment(text)) == settings)
    }

    @Test("A setting at its default is not written, so the shell decides it")
    func defaultsAreLeftOut() {
        let text = Parse.dropIn(for: ShellSettings())
        #expect(!text.contains("Environment="))
        #expect(Parse.shellSettings(Parse.unitEnvironment(text)) == ShellSettings())
    }

    @Test("One Environment line can set more than one variable, in quotes or not")
    func environmentWords() {
        let values = Parse.unitEnvironment(#"Environment=A=1 "B=two words" C=3"#)
        #expect(values == ["A": "1", "B": "two words", "C": "3"])
    }

    @Test("A value the shell does not read is the default")
    func unknownValues() {
        let settings = Parse.shellSettings(["APUS_RENDERER": "vulkan", "APUS_SCALE": "-2"])
        #expect(settings.renderer == .cpu)
        #expect(settings.scale == nil)
    }

    @Test("zone1970.tab gives the zones in order, with UTC first")
    func zones() {
        let zones = Parse.timeZones("""
            # comment
            JP\t+353916+1394441\tAsia/Tokyo
            AR\t-3436-05827\tAmerica/Argentina/Buenos_Aires\tBuenos Aires (BA, CF)
            """)
        #expect(zones.map(\.id) == ["UTC", "America/Argentina/Buenos_Aires", "Asia/Tokyo"])
        #expect(zones[1].city == "Buenos Aires")
        #expect(zones[1].region == "America / Argentina")
        #expect(zones[1].countries == ["AR"])
    }

    @Test("The zone comes from the link of /etc/localtime, relative or absolute")
    func zoneFromLink() {
        #expect(Parse.zone(fromLink: "../usr/share/zoneinfo/Europe/Berlin") == "Europe/Berlin")
        #expect(Parse.zone(fromLink: "/usr/share/zoneinfo/UTC") == "UTC")
        #expect(Parse.zone(fromLink: "/etc/somewhere") == nil)
    }

    @Test("A query finds a zone by its city, its region or its country")
    func zoneQuery() {
        let zone = TimeZoneEntry(id: "America/Argentina/Buenos_Aires", countries: ["AR"])
        #expect(Parse.matches(zone, query: "buenos"))
        #expect(Parse.matches(zone, query: "aires argentina"))
        #expect(Parse.matches(zone, query: "ar"))
        #expect(!Parse.matches(zone, query: "tokyo"))
    }

    @Test("The shadow line of root says whether it has a password")
    func shadow() {
        #expect(Parse.password(inShadow: "root::19000::::::\nbin:!*:19000::::::") == .none)
        #expect(Parse.password(inShadow: "root:$6$salt$hash:19000:0:99999:7:::") == .set)
        #expect(Parse.password(inShadow: "root:!$6$salt$hash:19000::::::") == .locked)
        #expect(Parse.password(inShadow: "root:*:19000::::::") == .locked)
        #expect(Parse.password(inShadow: "bin:x:1") == .unknown)
    }

    @Test("A host name is a label of DNS")
    func hostNames() {
        #expect(Parse.problem(withHostName: "apus-2") == nil)
        #expect(Parse.problem(withHostName: "") != nil)
        #expect(Parse.problem(withHostName: "my machine") != nil)
        #expect(Parse.problem(withHostName: "-apus") != nil)
        #expect(Parse.problem(withHostName: String(repeating: "a", count: 64)) != nil)
    }

    @Test("The default gateway of an interface, from /proc/net/route")
    func gateways() {
        let table = """
            Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask
            enp0s1\t00000000\t0140A8C0\t0003\t0\t0\t1024\t00000000
            enp0s1\t0040A8C0\t00000000\t0001\t0\t0\t1024\t00FFFFFF
            """
        #expect(Parse.gateways(table) == ["enp0s1": "192.168.64.1"])
    }

    @Test("The name servers of resolv.conf")
    func nameServers() {
        let text = "# resolved\nnameserver 192.168.64.1\nnameserver fd00::1\nsearch local\n"
        #expect(Parse.nameServers(text) == ["192.168.64.1", "fd00::1"])
    }

    @Test("A desktop entry reads its own group, without the translations")
    func desktopEntry() {
        let entry = Parse.desktopEntry("""
            [Desktop Entry]
            Type=Application
            Name=Chromium
            Name[de]=Chromium-Browser
            Exec=/usr/bin/chromium %U

            [Desktop Action new-window]
            Name=New Window
            """)
        #expect(entry["Name"] == "Chromium")
        #expect(entry["Type"] == "Application")
        #expect(entry.count == 3)
        #expect(Parse.program(ofExec: entry["Exec"]!) == "/usr/bin/chromium")
    }

    @Test("Hiding an app copies its entry with NoDisplay set, once")
    func hiding() {
        let original = """
            [Desktop Entry]
            Type=Application
            Name=htop
            NoDisplay=false
            [Desktop Action x]
            NoDisplay=keep
            """
        let hidden = Parse.hiding(original)
        #expect(hidden.hasPrefix(Parse.hiddenMarker))
        let entry = Parse.desktopEntry(hidden)
        #expect(entry["NoDisplay"] == "true")
        #expect(entry["Name"] == "htop")
        #expect(hidden.contains("NoDisplay=keep"), "another group keeps its own keys")
        #expect(hidden.split(separator: "\n").filter { $0 == "NoDisplay=true" }.count == 1)
    }

    @Test("A layout of the list matches the settings that name it")
    func layouts() {
        #expect(KeyboardLayout.matching(ShellSettings())?.name == "English (US)")
        #expect(KeyboardLayout.matching(ShellSettings(layout: "us", variant: "dvorak"))?.name
            == "English (Dvorak)")
        #expect(KeyboardLayout.matching(ShellSettings(layout: "xx")) == nil)
        #expect(Set(KeyboardLayout.all.map(\.id)).count == KeyboardLayout.all.count)
    }

    @Test("The sizes and the times, as a person reads them")
    func words() {
        #expect(humanSize(31 << 30) == "31 GB")
        #expect(humanSize(3 << 29) == "1.5 GB")
        #expect(duration(4000) == "1 hour, 6 minutes")
        #expect(duration(90_000) == "1 day, 1 hour")
        #expect(ClockReading(offset: 19_800).offsetText == "UTC+05:30")
        #expect(ClockReading(offset: -18_000).offsetText == "UTC−05:00")
    }
}
