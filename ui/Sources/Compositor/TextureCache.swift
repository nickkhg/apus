import CGLES
import Glibc
import Render

/// The textures that the GPU renderer draws from.
///
/// Two kinds of thing go into a texture, and both are kept between frames:
///
/// - A Bitmap: the pixels of a window, a run of text, or the pointer. The
///   key is the object. A window makes a new Bitmap for each commit, so a
///   new object means new pixels, and an object that stays is uploaded one
///   time.
/// - The coverage of a Path. The key is the path and the part of the screen
///   it was cut to. The shapes of a shell (the dock, the round corners of an
///   icon) do not change from frame to frame, so they are rasterized one
///   time.
///
/// The cache holds the Bitmap objects, so a freed object can never give its
/// address to a later one and read the wrong texture. Anything that no frame
/// used for `keepFrames` frames is removed.
final class TextureCache {
    /// How many frames a texture stays after its last use.
    private let keepFrames = 120

    private struct BitmapEntry {
        let texture: GLuint
        /// Holds the object, so that its address stays its own.
        let bitmap: Bitmap
        var lastUsed: Int
    }

    private struct MaskKey: Hashable {
        let path: Path
        let clip: Rect
    }

    struct MaskTexture {
        let texture: GLuint
        let rect: Rect
    }

    private struct MaskEntry {
        let texture: GLuint
        let rect: Rect
        var lastUsed: Int
    }

    private var bitmaps: [ObjectIdentifier: BitmapEntry] = [:]
    private var masks: [MaskKey: MaskEntry] = [:]
    private var frame = 0

    func startFrame() { frame += 1 }

    /// Removes what no recent frame used.
    func endFrame() {
        let oldest = frame - keepFrames
        for (key, entry) in bitmaps where entry.lastUsed < oldest {
            var texture = entry.texture
            glDeleteTextures(1, &texture)
            bitmaps[key] = nil
        }
        for (key, entry) in masks where entry.lastUsed < oldest {
            var texture = entry.texture
            glDeleteTextures(1, &texture)
            masks[key] = nil
        }
    }

    /// The texture of a bitmap, uploaded if it is new.
    func texture(for bitmap: Bitmap) -> GLuint {
        let key = ObjectIdentifier(bitmap)
        if var entry = bitmaps[key] {
            entry.lastUsed = frame
            bitmaps[key] = entry
            return entry.texture
        }
        let texture = make()
        bitmap.pixels.withUnsafeBytes { bytes in
            glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA,
                         GLsizei(bitmap.width), GLsizei(bitmap.height), 0,
                         GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), bytes.baseAddress)
        }
        bitmaps[key] = BitmapEntry(texture: texture, bitmap: bitmap, lastUsed: frame)
        return texture
    }

    /// The coverage of a path, in a texture. Nil when the path covers no
    /// pixel of the clip.
    func mask(for path: Path, clippedTo clip: Rect) -> MaskTexture? {
        let key = MaskKey(path: path, clip: clip)
        if var entry = masks[key] {
            entry.lastUsed = frame
            masks[key] = entry
            return MaskTexture(texture: entry.texture, rect: entry.rect)
        }
        guard let mask = SoftwareRenderer.mask(for: path, clippedTo: clip) else { return nil }
        let texture = make()
        mask.coverage.withUnsafeBytes { bytes in
            glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_ALPHA,
                         GLsizei(mask.width), GLsizei(mask.height), 0,
                         GLenum(GL_ALPHA), GLenum(GL_UNSIGNED_BYTE), bytes.baseAddress)
        }
        let rect = Rect(x: mask.x, y: mask.y, width: mask.width, height: mask.height)
        masks[key] = MaskEntry(texture: texture, rect: rect, lastUsed: frame)
        return MaskTexture(texture: texture, rect: rect)
    }

    /// Everything goes away with the GL context, so this only forgets.
    func clear() {
        bitmaps.removeAll()
        masks.removeAll()
    }

    private func make() -> GLuint {
        var texture: GLuint = 0
        glGenTextures(1, &texture)
        glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        // One texture pixel for one screen pixel, and no repeat at the edge.
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_NEAREST)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_NEAREST)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        return texture
    }
}
