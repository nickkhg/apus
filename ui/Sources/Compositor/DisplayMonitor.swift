import CUdev
import Glibc

/// Watches for a change of the display.
///
/// The kernel sends an event on the `drm` subsystem when a monitor is
/// connected or disconnected, and when a virtual screen takes a new size.
/// The compositor then reads the mode again. This is the same signal on real
/// hardware and in a virtual machine, so nothing here knows which one it is.
final class DisplayMonitor {
    private var udev: OpaquePointer?
    private var monitor: OpaquePointer?

    /// Called when the display reported a change.
    var changed: () -> Void = {}

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
        udev_monitor_filter_add_match_subsystem_devtype(monitor, "drm", nil)
        guard udev_monitor_enable_receiving(monitor) == 0 else { return nil }
    }

    deinit {
        if let monitor { udev_monitor_unref(monitor) }
        if let udev { udev_unref(udev) }
    }

    /// Reads the events that arrived. Several events give one call of
    /// `changed`, because a change often reports more than one event.
    func dispatch() {
        var reported = false
        while let device = udev_monitor_receive_device(monitor) {
            reported = true
            udev_device_unref(device)
        }
        if reported { changed() }
    }
}
