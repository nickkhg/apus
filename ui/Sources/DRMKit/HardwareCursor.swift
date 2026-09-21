import CDRM
import Glibc

/// The pointer on a plane of the display, and not in the frame.
///
/// A display has a small buffer for the pointer, which it puts over the
/// frame as it scans it out. Moving the pointer is then one call, and the
/// frame under it does not change. Without this the compositor draws the
/// whole screen again for every move of the mouse, which at 3200x2000 is
/// 6.4 million pixels for a pointer that moved three.
///
/// The display says how large the buffer must be (64x64 on most, and on
/// virtio-gpu). The picture of the pointer goes in the top left of it, and
/// the rest stays clear.
public final class HardwareCursor {
    /// The size the display asks for, not the size of the picture.
    public let width: Int
    public let height: Int

    private let fd: Int32
    private let crtcID: UInt32
    private let handle: UInt32
    private let pitch: Int
    private let size: Int
    private let pixels: UnsafeMutableRawPointer
    private var isShown = false

    /// Makes the buffer. It is not on the display until `show` says so.
    public init(device: DRMDevice, output: Output) throws(DRMError) {
        let fd = device.fd
        // A display that does not answer is asked for the usual size. The
        // call that puts the cursor on the display is the real test.
        var wanted: UInt64 = 0
        let width = drmGetCap(fd, CDRM_CAP_CURSOR_WIDTH, &wanted) == 0 && wanted > 0
            ? Int(wanted) : 64
        let height = drmGetCap(fd, CDRM_CAP_CURSOR_HEIGHT, &wanted) == 0 && wanted > 0
            ? Int(wanted) : 64

        var handle: UInt32 = 0, pitch: UInt32 = 0, size: UInt64 = 0
        guard drmModeCreateDumbBuffer(fd, UInt32(width), UInt32(height), 32, 0,
                                      &handle, &pitch, &size) == 0 else {
            throw .call("drmModeCreateDumbBuffer for the pointer", errno: errno)
        }
        var offset: UInt64 = 0
        guard drmModeMapDumbBuffer(fd, handle, &offset) == 0 else {
            let err = errno
            drmModeDestroyDumbBuffer(fd, handle)
            throw .call("drmModeMapDumbBuffer for the pointer", errno: err)
        }
        let mapped = mmap(nil, Int(size), PROT_READ | PROT_WRITE, MAP_SHARED, fd, off_t(offset))
        guard let mapped, mapped != MAP_FAILED else {
            let err = errno
            drmModeDestroyDumbBuffer(fd, handle)
            throw .call("mmap for the pointer", errno: err)
        }

        self.fd = fd
        self.crtcID = output.crtcID
        self.width = width
        self.height = height
        self.handle = handle
        self.pitch = Int(pitch)
        self.size = Int(size)
        self.pixels = mapped
        memset(mapped, 0, Int(size))
    }

    deinit {
        if isShown { drmModeSetCursor(fd, crtcID, 0, 0, 0) }
        munmap(pixels, size)
        drmModeDestroyDumbBuffer(fd, handle)
    }

    /// Writes the picture. `pixel` gives an ARGB8888 value for each place in
    /// the buffer, and 0 for the places the pointer does not cover.
    public func draw(_ pixel: (_ x: Int, _ y: Int) -> UInt32) {
        for row in 0..<height {
            let line = (pixels + row * pitch).assumingMemoryBound(to: UInt32.self)
            for column in 0..<width { line[column] = pixel(column, row) }
        }
    }

    /// Puts the cursor on the display. False means the display has no
    /// cursor plane, and the caller must draw the pointer into the frame.
    public func show() -> Bool {
        guard drmModeSetCursor(fd, crtcID, handle, UInt32(width), UInt32(height)) == 0 else {
            return false
        }
        isShown = true
        return true
    }

    /// Moves the top left corner of the picture to a place on the screen.
    public func move(toX x: Int, y: Int) {
        guard isShown else { return }
        drmModeMoveCursor(fd, crtcID, Int32(x), Int32(y))
    }
}
