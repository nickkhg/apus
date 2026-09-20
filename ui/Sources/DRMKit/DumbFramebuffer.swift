import CDRM
import Glibc

/// A CPU-drawable framebuffer ("dumb buffer"): 32-bit XRGB8888 pixels in
/// memory shared with the kernel. Any KMS driver supports these, with or
/// without a GPU.
public final class DumbFramebuffer {
    public let width: Int
    public let height: Int
    /// Bytes per row (may be larger than width * 4).
    public let pitch: Int
    /// The KMS framebuffer ID.
    public let id: UInt32

    private let fd: Int32
    private let handle: UInt32
    private let size: Int
    private let pixels: UnsafeMutableRawPointer

    public init(device: DRMDevice, width: Int, height: Int) throws(DRMError) {
        let fd = device.fd
        var handle: UInt32 = 0, pitch: UInt32 = 0, size: UInt64 = 0
        guard drmModeCreateDumbBuffer(fd, UInt32(width), UInt32(height), 32, 0,
                                      &handle, &pitch, &size) == 0 else {
            throw .call("drmModeCreateDumbBuffer", errno: errno)
        }

        var offset: UInt64 = 0
        guard drmModeMapDumbBuffer(fd, handle, &offset) == 0 else {
            let err = errno
            drmModeDestroyDumbBuffer(fd, handle)
            throw .call("drmModeMapDumbBuffer", errno: err)
        }
        let mapped = mmap(nil, Int(size), PROT_READ | PROT_WRITE, MAP_SHARED, fd, off_t(offset))
        guard let mapped, mapped != MAP_FAILED else {
            let err = errno
            drmModeDestroyDumbBuffer(fd, handle)
            throw .call("mmap", errno: err)
        }

        let handles: [UInt32] = [handle, 0, 0, 0]
        let pitches: [UInt32] = [pitch, 0, 0, 0]
        let offsets: [UInt32] = [0, 0, 0, 0]
        var id: UInt32 = 0
        guard drmModeAddFB2(fd, UInt32(width), UInt32(height), CDRM_FORMAT_XRGB8888,
                            handles, pitches, offsets, &id, 0) == 0 else {
            let err = errno
            munmap(mapped, Int(size))
            drmModeDestroyDumbBuffer(fd, handle)
            throw .call("drmModeAddFB2", errno: err)
        }

        self.fd = fd
        self.width = width
        self.height = height
        self.pitch = Int(pitch)
        self.id = id
        self.handle = handle
        self.size = Int(size)
        self.pixels = mapped
    }

    deinit {
        drmModeRmFB(fd, id)
        munmap(pixels, size)
        drmModeDestroyDumbBuffer(fd, handle)
    }

    /// Direct access to the pixels: a pointer to the first one, and the
    /// distance between rows in pixels (pitch / 4).
    public func withPixels<R>(_ body: (UnsafeMutablePointer<UInt32>, _ stride: Int) throws -> R) rethrows -> R {
        try body(pixels.assumingMemoryBound(to: UInt32.self), pitch / 4)
    }

    /// Writes the pixels as a binary PPM (P6), for the tests.
    public func writePPM(to path: String) throws(DRMError) {
        // The mapping lives as long as this object, so the pointer is safe
        // to keep for the call. withPixels rethrows an untyped error, which
        // a typed throw cannot pass on.
        let (start, rowStride) = withPixels { ($0, $1) }
        try PPM.write(width: width, height: height, to: path) { x, y in
            start[y * rowStride + x] & 0xFFFFFF   // XRGB8888
        }
    }

    /// Fills a rectangle (clipped to the buffer) with a 0xRRGGBB colour.
    public func fill(x: Int = 0, y: Int = 0, width: Int? = nil, height: Int? = nil, color: UInt32) {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(self.width, x + (width ?? self.width))
        let y1 = min(self.height, y + (height ?? self.height))
        guard x0 < x1, y0 < y1 else { return }
        for row in y0..<y1 {
            let line = (pixels + row * pitch).assumingMemoryBound(to: UInt32.self)
            UnsafeMutableBufferPointer(start: line + x0, count: x1 - x0).update(repeating: color)
        }
    }
}
