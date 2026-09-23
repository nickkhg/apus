import Toolkit

// Power in a tile of 256 points: how much is left and what is happening to
// it, which is what a person glances at. A machine with no battery says so.

public struct PowerTile: View {
    let store: PowerStore

    public init(store: PowerStore) {
        self.store = store
    }

    private var reading: PowerReading { store.reading }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Ink.mark)
                    .frame(width: 8, height: 8)
                Text("Power")
                    .font(Font(size: 13, weight: .bold))
                    .foregroundColor(Ink.text)
                Spacer()
            }
            switch reading.source {
            case .nothingReported, .mains:
                Text(reading.source == .mains ? "AC" : "No battery")
                    .font(Font(size: reading.source == .mains ? 46 : 28, weight: .bold))
                    .foregroundColor(Ink.text)
                    .padding(.top, 14)
                Text(reading.source == .mains ? "ON AC POWER"
                     : store.machine == .appleVM ? "THE MAC HAS THE POWER" : "NONE THAT THE KERNEL NAMES")
                    .font(Font(size: 10, weight: .bold))
                    .foregroundColor(Ink.dimText)
                    .padding(.top, 4)
                Spacer()
                PlugMark()
                    .frame(width: 44, height: 44)
            case .battery, .batteryOnMains:
                HStack(alignment: .bottom, spacing: 2) {
                    Text(reading.capacity.map { "\(Int($0.rounded()))" } ?? "—")
                        .font(Font(size: 46, weight: .bold))
                        .foregroundColor(Ink.text)
                    Text("%")
                        .font(Font(size: 23))
                        .foregroundColor(Ink.dimText)
                        .padding(.bottom, 6)
                }
                .padding(.top, 12)
                Text(reading.state.uppercased())
                    .font(Font(size: 10, weight: .bold))
                    .foregroundColor(Ink.dimText)
                    .padding(.top, 4)
                BatteryMark(percent: reading.capacity ?? 0)
                    .frame(width: 84, height: 36)
                    .padding(.top, 16)
                Spacer()
                if let watts = reading.watts {
                    HStack(spacing: 6) {
                        Text(Words.watts(watts))
                            .font(Font(size: 15, weight: .bold))
                            .foregroundColor(Ink.text)
                        Text(reading.isCharging ? "going in" : "going out")
                            .font(Font(size: 11))
                            .foregroundColor(Ink.dimText)
                        Spacer()
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.background)
        .clipped()
    }
}
