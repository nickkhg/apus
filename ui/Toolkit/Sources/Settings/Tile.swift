import Toolkit

// Settings in a tile of 256 points. A tile is read from the corner of an
// eye, so it holds what a person glances at: the time where this machine
// is, what it is called, where it is on the network, and whether root is
// open to anyone.

public struct SettingsTile: View {
    let store: SettingsStore

    public init(store: SettingsStore) {
        self.store = store
    }

    private var snapshot: Snapshot { store.snapshot }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Ink.mark)
                    .frame(width: 8, height: 8)
                Text("Settings")
                    .font(Font(size: 13, weight: .bold))
                    .foregroundColor(Ink.text)
                Spacer()
            }
            Text(store.clock.time)
                .font(Font(size: 46, weight: .bold))
                .foregroundColor(Ink.text)
                .padding(.top, 12)
            Text("\(TimeZoneEntry(id: snapshot.time.zone).city.uppercased()) · \(store.clock.abbreviation)")
                .font(Font(size: 10, weight: .bold))
                .foregroundColor(Ink.dimText)
                .padding(.top, 2)
            Divider(thickness: 1)
                .foregroundColor(Ink.divider)
                .padding(.top, 16)
            line("NAME", snapshot.about.hostName)
                .padding(.top, 14)
            line("ADDRESS", address)
                .padding(.top, 10)
            Spacer()
            if snapshot.password == .none {
                HStack(spacing: 8) {
                    Circle().fill(Ink.warning).frame(width: 6, height: 6)
                    Text("root has no password")
                        .font(Font(size: 11))
                        .foregroundColor(Ink.warning)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.background)
        .clipped()
    }

    private var address: String {
        snapshot.interfaces.first { $0.isConnected && !$0.ipv4.isEmpty }?.ipv4.first
            .map { String($0.prefix { $0 != "/" }) } ?? "Offline"
    }

    private func line(_ name: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(Font(size: 10, weight: .bold))
                .foregroundColor(Ink.dimText)
            Spacer()
            Text(value)
                .font(Font(size: 12))
                .foregroundColor(Ink.secondaryText)
        }
    }
}
