import DRMKit
import Render

/// The pointer of a screen.
///
/// The display draws it over the frame, on a plane of its own, when it has
/// one. Moving the pointer is then one call to the display and no frame at
/// all. A display with no cursor plane leaves `isOnDisplay` false, and the
/// compositor puts the pointer in the display list as it did before.
///
/// Both screens hold one of these: the plane belongs to the display, and
/// not to the way the frames are drawn.
struct ScreenPointer {
    /// True when the display draws the pointer.
    private(set) var isOnDisplay = false
    /// The picture the display draws, and where. A screenshot holds this
    /// over the frame, because that is what a person sees.
    var picture: (bitmap: Bitmap, x: Int, y: Int)? {
        guard isOnDisplay, let bitmap else { return nil }
        return (bitmap, at.x, at.y)
    }

    private var cursor: HardwareCursor?
    private var bitmap: Bitmap?
    private var crtcID: UInt32?
    private var at = (x: 0, y: 0)
    /// The display is asked once. A display that refuses is not asked again
    /// for every new size or picture.
    private var refused = false

    /// Gives the display the picture of the pointer. The picture goes in the
    /// top left of the buffer that the display asks for, and the rest of the
    /// buffer stays clear.
    mutating func use(_ bitmap: Bitmap, device: DRMDevice, output: Output) {
        guard !refused else { return }
        if crtcID != output.crtcID {
            cursor = nil
            isOnDisplay = false
        }
        if cursor == nil {
            do {
                cursor = try HardwareCursor(device: device, output: output)
                crtcID = output.crtcID
            } catch {
                refused = true
                log("screen: the display has no pointer of its own (\(error)); "
                    + "the pointer goes in the frame")
                return
            }
        }
        guard let cursor else { return }
        if bitmap.width > cursor.width || bitmap.height > cursor.height {
            refused = true
            self.cursor = nil
            log("screen: the pointer is \(bitmap.width)x\(bitmap.height) and the display "
                + "takes \(cursor.width)x\(cursor.height); the pointer goes in the frame")
            return
        }
        cursor.draw { x, y in
            guard x < bitmap.width, y < bitmap.height else { return 0 }
            return bitmap.pixels[y * bitmap.width + x]
        }
        guard cursor.show() else {
            refused = true
            self.cursor = nil
            log("screen: the display refused a pointer of its own; "
                + "the pointer goes in the frame")
            return
        }
        isOnDisplay = true
        self.bitmap = bitmap
        cursor.move(toX: at.x, y: at.y)
        log("SCREEN-POINTER the display draws the pointer, "
            + "\(cursor.width)x\(cursor.height)")
    }

    mutating func move(toX x: Int, y: Int) {
        at = (x, y)
        cursor?.move(toX: x, y: y)
    }
}
