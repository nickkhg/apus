import CDRM
import Glibc

/// Anything that the display can scan out: a KMS framebuffer.
///
/// A DumbFramebuffer is memory that the CPU draws into. An
/// ImportedFramebuffer is memory that another library allocated, for
/// example a GBM buffer object that the GPU rendered into. The display does
/// not know the difference, so page flips take either one.
public protocol Framebuffer: AnyObject {
    /// The KMS framebuffer ID.
    var id: UInt32 { get }
    var width: Int { get }
    var height: Int { get }
}

extension DumbFramebuffer: Framebuffer {}

/// A KMS framebuffer for memory that another library allocated.
///
/// The framebuffer holds no memory of its own: the owner of the buffer must
/// keep it alive while the display shows it.
public final class ImportedFramebuffer: Framebuffer {
    public let id: UInt32
    public let width: Int
    public let height: Int
    private let fd: Int32

    /// `handle` is a GEM handle for this device, `pitch` the bytes in a row,
    /// and `format` a DRM_FORMAT_* value.
    public init(device: DRMDevice, width: Int, height: Int, format: UInt32,
                handle: UInt32, pitch: UInt32, offset: UInt32 = 0) throws(DRMError) {
        let handles: [UInt32] = [handle, 0, 0, 0]
        let pitches: [UInt32] = [pitch, 0, 0, 0]
        let offsets: [UInt32] = [offset, 0, 0, 0]
        var id: UInt32 = 0
        guard drmModeAddFB2(device.fd, UInt32(width), UInt32(height), format,
                            handles, pitches, offsets, &id, 0) == 0 else {
            throw .call("drmModeAddFB2", errno: errno)
        }
        self.id = id
        self.width = width
        self.height = height
        self.fd = device.fd
    }

    deinit { drmModeRmFB(fd, id) }
}
