import CUdev
import Glibc

/// Watches for a device that a person plugs in or takes out, so that the
/// shell can say so with a sound.
///
/// It listens for whole USB devices (`usb_device`), not for their
/// interfaces or for what the kernel makes of them: one stick is one event,
/// not the five that its disk, its partitions and its driver make. The
/// monitor starts with the session, so the devices that were there before
/// make no sound.
final class DeviceMonitor {
    enum Change { case added, removed }

    private var udev: OpaquePointer?
    private var monitor: OpaquePointer?

    /// Called once for the events that arrived together. A hub with three
    /// devices on it is one sound, not three.
    var changed: (Change, String) -> Void = { _, _ in }

    /// The file to watch. It becomes readable when an event arrives.
    var fd: Int32 { monitor.map { udev_monitor_get_fd($0) } ?? -1 }

    init?() {
        guard let udev = udev_new() else { return nil }
        self.udev = udev
        guard let monitor = udev_monitor_new_from_netlink(udev, "udev") else {
            udev_unref(udev)
            self.udev = nil
            return nil
        }
        self.monitor = monitor
        udev_monitor_filter_add_match_subsystem_devtype(monitor, "usb", "usb_device")
        guard udev_monitor_enable_receiving(monitor) == 0 else { return nil }
    }

    deinit {
        if let monitor { udev_monitor_unref(monitor) }
        if let udev { udev_unref(udev) }
    }

    /// Reads the events that arrived. The last add or remove among them is
    /// the one that is reported.
    func dispatch() {
        var last: (Change, String)?
        while let device = udev_monitor_receive_device(monitor) {
            defer { udev_device_unref(device) }
            let action = udev_device_get_action(device).map { String(cString: $0) } ?? ""
            let change: Change
            switch action {
            case "add": change = .added
            case "remove": change = .removed
            default: continue
            }
            last = (change, Self.name(of: device))
        }
        if let last { changed(last.0, last.1) }
    }

    /// What the device calls itself, or its place on the bus.
    private static func name(of device: OpaquePointer) -> String {
        for key in ["ID_MODEL_FROM_DATABASE", "ID_MODEL", "PRODUCT"] {
            if let value = udev_device_get_property_value(device, key), value.pointee != 0 {
                return String(cString: value)
            }
        }
        return udev_device_get_sysname(device).map { String(cString: $0) } ?? "a device"
    }
}
