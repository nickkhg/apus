import CFreeType
import CHarfBuzz
import Render
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// Text needs two C libraries: FreeType turns a glyph into pixels, and
// HarfBuzz decides which glyphs a string needs and where they go. The cache
// keeps one face for each font and size, and one image for each glyph that
// was drawn before.

/// A glyph drawn into an 8-bit coverage map.
struct GlyphImage {
    /// 0 (nothing) to 255 (the full colour), `width` values per row.
    let coverage: [UInt8]
    let width: Int
    let height: Int
    /// Where the top-left corner of the image goes, from the pen position on
    /// the baseline.
    let left: Int
    let top: Int
}

/// One glyph of a shaped string, and where it goes from the start of the text.
struct PlacedGlyph {
    let id: UInt32
    let x: Double
    let y: Double
}

/// A string after shaping: the glyphs to draw and the space it needs.
struct ShapedText {
    let glyphs: [PlacedGlyph]
    let width: Double
    let ascent: Double
    let descent: Double

    var height: Double { ascent + descent }

    static let empty = ShapedText(glyphs: [], width: 0, ascent: 0, descent: 0)
}

/// Loads fonts and keeps what was measured and drawn before.
///
/// A FreeType library handle is not safe for two threads at the same time,
/// and neither is the cache, so a lock protects both. The compositor uses one
/// thread and never waits for it.
final class FontCache {
    nonisolated(unsafe) static let shared = FontCache()

    private var library: FT_Library?
    private var faces: [String: LoadedFace] = [:]
    private var pictures: [PictureKey: Bitmap] = [:]
    private let lock = Lock()

    /// How many pictures of lines the cache holds. A shell draws a few tens
    /// of them. A terminal that scrolls makes a new line every time, so the
    /// cache empties itself instead of growing without end.
    private static let pictureLimit = 256

    /// Everything that a picture of a line depends on.
    private struct PictureKey: Hashable {
        let string: String
        let font: Font
        let color: Color
        /// The width that the line was cut to, in pixels.
        let room: Double
    }

    /// The font files to look for. The first one that opens wins. On
    /// Apus the ttf-dejavu package installs the DejaVu files, and the
    /// apus-ui package depends on it. The macOS files are for the tests
    /// and for a preview on the Mac: the Mac draws a different face.
    private static let files: [(monospaced: Bool, bold: Bool, paths: [String])] = [
        (false, false, ["/usr/share/fonts/TTF/DejaVuSans.ttf",
                        "/usr/share/fonts/dejavu/DejaVuSans.ttf",
                        "/System/Library/Fonts/Supplemental/Arial.ttf"]),
        (false, true, ["/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
                       "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
                       "/System/Library/Fonts/Supplemental/Arial Bold.ttf"]),
        (true, false, ["/usr/share/fonts/TTF/DejaVuSansMono.ttf",
                       "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
                       "/System/Library/Fonts/Menlo.ttc"]),
        (true, true, ["/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf",
                      "/usr/share/fonts/dejavu/DejaVuSansMono-Bold.ttf",
                      "/System/Library/Fonts/Menlo.ttc"]),
    ]

    private init() {
        if FT_Init_FreeType(&library) != 0 { library = nil }
    }

    /// Shapes `string` and gives the glyphs to draw. An empty result means
    /// that no font opened.
    /// The picture of a line of text, drawn one time.
    ///
    /// Two frames that draw the same line in the same colour at the same
    /// width get the same picture, and the same object. The CPU renderer
    /// then draws pixels that are ready, and the GPU renderer finds the
    /// texture that it made for that object in `TextureCache`.
    func picture(_ string: String, font: Font, color: Color, room: Double,
                 make: () -> Bitmap?) -> Bitmap? {
        let key = PictureKey(string: string, font: font, color: color, room: room)
        if let picture = lock.locked({ pictures[key] }) { return picture }
        guard let picture = make() else { return nil }
        lock.locked {
            if pictures.count >= FontCache.pictureLimit { pictures.removeAll(keepingCapacity: true) }
            pictures[key] = picture
        }
        return picture
    }

    func shape(_ string: String, font: Font) -> ShapedText {
        lock.locked {
            guard !string.isEmpty, let face = face(for: font) else { return .empty }
            return face.shape(string)
        }
    }

    /// The pixels of one glyph.
    func image(of glyph: UInt32, font: Font) -> GlyphImage? {
        lock.locked { face(for: font)?.image(of: glyph) }
    }

    private func face(for font: Font) -> LoadedFace? {
        guard let library else { return nil }
        let pixelSize = max(1, Int(font.size.rounded()))
        let bold = font.weight == .bold
        guard let path = FontCache.path(monospaced: font.isMonospaced, bold: bold) else { return nil }
        let key = "\(path)@\(pixelSize)"
        if let face = faces[key] { return face }
        guard let face = LoadedFace(library: library, path: path, pixelSize: pixelSize) else { return nil }
        faces[key] = face
        return face
    }

    /// The first file that exists for this style. A missing bold or
    /// monospaced file falls back to the plain face.
    private static func path(monospaced: Bool, bold: Bool) -> String? {
        let wanted = [(monospaced, bold), (monospaced, false), (false, bold), (false, false)]
        for (isMono, isBold) in wanted {
            guard let entry = files.first(where: { $0.monospaced == isMono && $0.bold == isBold })
            else { continue }
            if let path = entry.paths.first(where: { access($0, R_OK) == 0 }) { return path }
        }
        return nil
    }
}

/// One FreeType face at one pixel size, with its HarfBuzz font.
private final class LoadedFace {
    private let face: FT_Face
    private let hbFont: OpaquePointer
    private var images: [UInt32: GlyphImage] = [:]
    let ascent: Double
    let descent: Double

    /// FT_LOAD_RENDER: FreeType's load flags are macros, which Swift does not
    /// import, so the value is here.
    private static let loadRender: Int32 = 1 << 2

    init?(library: FT_Library, path: String, pixelSize: Int) {
        var face: FT_Face?
        guard FT_New_Face(library, path, 0, &face) == 0, let face else { return nil }
        guard FT_Set_Pixel_Sizes(face, 0, UInt32(pixelSize)) == 0 else {
            FT_Done_Face(face)
            return nil
        }
        guard let hbFont = hb_ft_font_create_referenced(face) else {
            FT_Done_Face(face)
            return nil
        }
        self.face = face
        self.hbFont = hbFont
        // The metrics are 26.6 fixed-point numbers: 64 units to the pixel.
        let metrics = face.pointee.size.pointee.metrics
        ascent = Double(metrics.ascender) / 64
        descent = Double(-metrics.descender) / 64
    }

    deinit {
        hb_font_destroy(hbFont)
        FT_Done_Face(face)
    }

    func shape(_ string: String) -> ShapedText {
        guard let buffer = hb_buffer_create() else { return .empty }
        defer { hb_buffer_destroy(buffer) }
        string.withCString { bytes in
            hb_buffer_add_utf8(buffer, bytes, -1, 0, -1)
        }
        // Direction, script and language from the text itself.
        hb_buffer_guess_segment_properties(buffer)
        hb_shape(hbFont, buffer, nil, 0)

        var count: UInt32 = 0
        let infos = hb_buffer_get_glyph_infos(buffer, &count)
        let positions = hb_buffer_get_glyph_positions(buffer, &count)
        guard let infos, let positions else { return .empty }

        var glyphs: [PlacedGlyph] = []
        glyphs.reserveCapacity(Int(count))
        var pen = (x: 0.0, y: 0.0)
        for index in 0..<Int(count) {
            let position = positions[index]
            glyphs.append(PlacedGlyph(id: infos[index].codepoint,
                                      x: pen.x + Double(position.x_offset) / 64,
                                      y: pen.y - Double(position.y_offset) / 64))
            pen.x += Double(position.x_advance) / 64
            pen.y -= Double(position.y_advance) / 64
        }
        return ShapedText(glyphs: glyphs, width: pen.x, ascent: ascent, descent: descent)
    }

    func image(of glyph: UInt32) -> GlyphImage? {
        if let image = images[glyph] { return image }
        guard FT_Load_Glyph(face, glyph, LoadedFace.loadRender) == 0 else { return nil }
        let slot = face.pointee.glyph.pointee
        let bitmap = slot.bitmap
        let width = Int(bitmap.width)
        let height = Int(bitmap.rows)
        var coverage = [UInt8](repeating: 0, count: width * height)
        if let source = bitmap.buffer, width > 0, height > 0 {
            let pitch = Int(bitmap.pitch)
            for row in 0..<height {
                // A negative pitch means that the rows go bottom to top.
                let start = pitch >= 0 ? row * pitch : (height - 1 - row) * -pitch
                for column in 0..<width {
                    coverage[row * width + column] = source[start + column]
                }
            }
        }
        let image = GlyphImage(coverage: coverage, width: width, height: height,
                               left: Int(slot.bitmap_left), top: Int(slot.bitmap_top))
        images[glyph] = image
        return image
    }
}


/// A mutex. Foundation is not needed for one lock.
final class Lock {
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>

    init() {
        mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        mutex.initialize(to: pthread_mutex_t())
        pthread_mutex_init(mutex, nil)
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    func locked<Value>(_ body: () -> Value) -> Value {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return body()
    }
}
