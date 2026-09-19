import CDRM
import Glibc

public enum DRMError: Error, CustomStringConvertible {
    case open(path: String, errno: Int32)
    case noDevice
    case resources
    case noCRTC(connector: String)
    case call(String, errno: Int32)

    public var description: String {
        switch self {
        case .open(let path, let err): "can't open \(path): \(String(cString: strerror(err)))"
        case .noDevice: "no DRM device with a connected output"
        case .resources: "can't read DRM resources (not a KMS device?)"
        case .noCRTC(let name): "no free CRTC for \(name)"
        case .call(let name, let err): "\(name) failed: \(String(cString: strerror(err)))"
        }
    }
}

/// A display mode (resolution and refresh rate) as the kernel reports it.
public struct Mode: Sendable, CustomStringConvertible {
    let info: drmModeModeInfo
    public var width: Int { Int(info.hdisplay) }
    public var height: Int { Int(info.vdisplay) }
    public var refreshRate: Int { Int(info.vrefresh) }
    public var description: String { "\(width)x\(height)@\(refreshRate)Hz" }
}

/// A connected output (monitor) and the CRTC that will drive it.
public struct Output: Sendable, CustomStringConvertible {
    public let name: String
    public let connectorID: UInt32
    public let crtcID: UInt32
    public let mode: Mode
    public var description: String { "\(name) \(mode)" }
}

/// An open DRM device node, e.g. /dev/dri/card0.
public final class DRMDevice {
    public let path: String
    public let fd: Int32
    private let ownsFD: Bool

    public init(path: String) throws(DRMError) {
        let fd = Glibc.open(path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { throw .open(path: path, errno: errno) }
        self.path = path
        self.fd = fd
        self.ownsFD = true
    }

    /// Wraps a device opened elsewhere (e.g. by libseat, which also closes it).
    public init(fd: Int32, path: String) {
        self.path = path
        self.fd = fd
        self.ownsFD = false
    }

    deinit { if ownsFD { close(fd) } }

    /// The first /dev/dri/card* that has at least one connected output.
    public static func firstWithOutput() throws(DRMError) -> DRMDevice {
        for index in 0..<8 {
            guard let device = try? DRMDevice(path: "/dev/dri/card\(index)") else { continue }
            if let outputs = try? device.connectedOutputs(), !outputs.isEmpty { return device }
        }
        throw .noDevice
    }

    /// Connected outputs, each with its preferred mode and a CRTC to drive it.
    public func connectedOutputs() throws(DRMError) -> [Output] {
        guard let resources = drmModeGetResources(fd) else { throw .resources }
        defer { drmModeFreeResources(resources) }
        let res = resources.pointee

        var outputs: [Output] = []
        var usedCRTCs: Set<UInt32> = []
        for i in 0..<Int(res.count_connectors) {
            guard let connector = drmModeGetConnector(fd, res.connectors[i]) else { continue }
            defer { drmModeFreeConnector(connector) }
            let conn = connector.pointee
            guard conn.connection == DRM_MODE_CONNECTED, conn.count_modes > 0 else { continue }

            let modes = UnsafeBufferPointer(start: conn.modes, count: Int(conn.count_modes))
            let preferred = modes.first { $0.type & UInt32(DRM_MODE_TYPE_PREFERRED) != 0 } ?? modes[0]
            let type = drmModeGetConnectorTypeName(conn.connector_type).map { String(cString: $0) } ?? "Unknown"
            let name = "\(type)-\(conn.connector_type_id)"

            guard let crtc = findCRTC(for: conn, in: res, excluding: usedCRTCs) else {
                throw .noCRTC(connector: name)
            }
            usedCRTCs.insert(crtc)
            outputs.append(Output(name: name, connectorID: conn.connector_id, crtcID: crtc,
                                  mode: Mode(info: preferred)))
        }
        return outputs
    }

    /// Prefer the CRTC the connector's current encoder uses, else any CRTC one
    /// of its encoders can drive.
    private func findCRTC(for conn: drmModeConnector, in res: drmModeRes,
                          excluding used: Set<UInt32>) -> UInt32? {
        if conn.encoder_id != 0, let encoder = drmModeGetEncoder(fd, conn.encoder_id) {
            defer { drmModeFreeEncoder(encoder) }
            let crtc = encoder.pointee.crtc_id
            if crtc != 0, !used.contains(crtc) { return crtc }
        }
        for e in 0..<Int(conn.count_encoders) {
            guard let encoder = drmModeGetEncoder(fd, conn.encoders[e]) else { continue }
            defer { drmModeFreeEncoder(encoder) }
            for c in 0..<Int(res.count_crtcs) where encoder.pointee.possible_crtcs & (1 << c) != 0 {
                if !used.contains(res.crtcs[c]) { return res.crtcs[c] }
            }
        }
        return nil
    }

    /// Shows `framebuffer` on `output`. The returned value puts back whatever
    /// was on screen before (e.g. the text console) when you call restore().
    public func show(_ framebuffer: DumbFramebuffer, on output: Output) throws(DRMError) -> ScreenRestore {
        let previous = drmModeGetCrtc(fd, output.crtcID)
        var connector = output.connectorID
        var mode = output.mode.info
        guard drmModeSetCrtc(fd, output.crtcID, framebuffer.id, 0, 0, &connector, 1, &mode) == 0 else {
            let err = errno
            if let previous { drmModeFreeCrtc(previous) }
            throw .call("drmModeSetCrtc", errno: err)
        }
        return ScreenRestore(fd: fd, connector: output.connectorID, previous: previous)
    }
}

/// Undoes DRMDevice.show(_:on:).
public final class ScreenRestore {
    private let fd: Int32
    private let connector: UInt32
    private var previous: UnsafeMutablePointer<drmModeCrtc>?

    init(fd: Int32, connector: UInt32, previous: UnsafeMutablePointer<drmModeCrtc>?) {
        self.fd = fd
        self.connector = connector
        self.previous = previous
    }

    public func restore() {
        guard let previous else { return }
        var crtc = previous.pointee
        var connector = connector
        _ = drmModeSetCrtc(fd, crtc.crtc_id, crtc.buffer_id, crtc.x, crtc.y, &connector, 1, &crtc.mode)
        drmModeFreeCrtc(previous)
        self.previous = nil
    }

    deinit { restore() }
}
