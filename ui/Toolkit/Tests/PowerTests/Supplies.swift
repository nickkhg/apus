@testable import Power
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Render
import Toolkit

/// The supplies of a machine for the tests: the `uevent` text of each, as
/// the kernel writes it.
final class Supplies: PowerSource {
    var files: [(name: String, uevent: String)]
    var machine: MachineKind

    init(_ files: [(name: String, uevent: String)], machine: MachineKind = .unknown) {
        self.files = files
        self.machine = machine
    }

    func supplies() -> [(name: String, uevent: String)] { files }
}

/// Real files, from a laptop that counts its battery in energy.
enum Sample {
    static let energyBattery = """
        POWER_SUPPLY_NAME=BAT0
        POWER_SUPPLY_TYPE=Battery
        POWER_SUPPLY_STATUS=Discharging
        POWER_SUPPLY_PRESENT=1
        POWER_SUPPLY_TECHNOLOGY=Li-poly
        POWER_SUPPLY_CYCLE_COUNT=212
        POWER_SUPPLY_VOLTAGE_MIN_DESIGN=15440000
        POWER_SUPPLY_VOLTAGE_NOW=16021000
        POWER_SUPPLY_POWER_NOW=7400000
        POWER_SUPPLY_ENERGY_FULL_DESIGN=57000000
        POWER_SUPPLY_ENERGY_FULL=52600000
        POWER_SUPPLY_ENERGY_NOW=41200000
        POWER_SUPPLY_CAPACITY=78
        POWER_SUPPLY_CAPACITY_LEVEL=Normal
        POWER_SUPPLY_MODEL_NAME=5B10W13930
        POWER_SUPPLY_MANUFACTURER=SMP
        """

    /// A battery that counts in charge, with a current below zero.
    static let chargeBattery = """
        POWER_SUPPLY_NAME=BAT1
        POWER_SUPPLY_TYPE=Battery
        POWER_SUPPLY_STATUS=Charging
        POWER_SUPPLY_PRESENT=1
        POWER_SUPPLY_VOLTAGE_NOW=12000000
        POWER_SUPPLY_CURRENT_NOW=-1500000
        POWER_SUPPLY_CHARGE_FULL=4000000
        POWER_SUPPLY_CHARGE_NOW=2000000
        POWER_SUPPLY_TEMP=312
        """

    static let adapter = """
        POWER_SUPPLY_NAME=AC
        POWER_SUPPLY_TYPE=Mains
        POWER_SUPPLY_ONLINE=1
        """

    static let unplugged = """
        POWER_SUPPLY_NAME=AC
        POWER_SUPPLY_TYPE=Mains
        POWER_SUPPLY_ONLINE=0
        """

    static let usbPort = """
        POWER_SUPPLY_NAME=ucsi-source-psy-USBC000:001
        POWER_SUPPLY_TYPE=USB
        POWER_SUPPLY_ONLINE=0
        """

    static let mouse = """
        POWER_SUPPLY_NAME=hidpp_battery_0
        POWER_SUPPLY_TYPE=Battery
        POWER_SUPPLY_SCOPE=Device
        POWER_SUPPLY_STATUS=Discharging
        POWER_SUPPLY_CAPACITY=55
        POWER_SUPPLY_MODEL_NAME=MX Master 3
        """
}

/// Draws a view into pixels. When APUS_PREVIEWS names a folder, the
/// picture is also written there as a PPM. See docs/toolkit.md#tests.
@discardableResult
func preview(_ view: some View, width: Int, height: Int, name: String) -> [UInt32] {
    let list = ViewRenderer.displayList(for: view, in: Rect(x: 0, y: 0, width: width, height: height))
    var pixels = [UInt32](repeating: 0xFF000000, count: width * height)
    pixels.withUnsafeMutableBufferPointer { memory in
        SoftwareRenderer.render(list, into: Canvas(pixels: memory.baseAddress!, width: width,
                                                   height: height, stride: width))
    }
    if let folder = getenv("APUS_PREVIEWS").map({ String(cString: $0) }),
       let file = fopen("\(folder)/\(name).ppm", "wb") {
        defer { fclose(file) }
        let head = Array("P6\n\(width) \(height)\n255\n".utf8)
        fwrite(head, 1, head.count, file)
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 3)
        for pixel in pixels {
            bytes += [UInt8((pixel >> 16) & 0xFF), UInt8((pixel >> 8) & 0xFF), UInt8(pixel & 0xFF)]
        }
        fwrite(bytes, 1, bytes.count, file)
    }
    return pixels
}
