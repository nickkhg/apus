import Render
import Testing
@testable import Toolkit

// The tests need a font file. The builder container installs ttf-dejavu, as
// the image does. Without a font, Text draws nothing, and the first test
// says so instead of the others failing one by one.

private let font = Font(size: 16)

private func bitmaps(_ view: some View, width: Int, height: Int) -> [(Bitmap, Int, Int)] {
    ViewRenderer.displayList(for: view, in: Rect(x: 0, y: 0, width: width, height: height))
        .compactMap { item in
            if case .bitmap(let bitmap, let x, let y) = item { (bitmap, x, y) } else { nil }
        }
}

@Suite("Text")
struct TextTests {
    @Test("A font is installed, and shaping gives one glyph for each letter")
    func fontIsInstalled() {
        let shaped = FontCache.shared.shape("Hi", font: font)
        #expect(shaped.glyphs.count == 2, "no font file: install ttf-dejavu")
        #expect(shaped.width > 0)
        #expect(shaped.ascent > 0 && shaped.descent > 0)
    }

    @Test("Text asks for the width of its glyphs and the height of a line")
    func textSize() {
        let size = ViewRenderer.size(of: Text("Hello").font(font), fitting: .unspecified)
        #expect(size.width > 10)
        #expect(size.height >= 16 && size.height < 32)
    }

    @Test("A longer string is wider")
    func longerStringIsWider() {
        let short = ViewRenderer.size(of: Text("i").font(font), fitting: .unspecified)
        let long = ViewRenderer.size(of: Text("iiiiii").font(font), fitting: .unspecified)
        #expect(long.width > short.width)
    }

    @Test("Every glyph of a monospaced font has the same width")
    func monospacedWidths() {
        let mono = Font.monospaced(size: 16)
        let narrow = FontCache.shared.shape("ii", font: mono).width
        let wide = FontCache.shared.shape("WW", font: mono).width
        #expect(narrow == wide)
        // The same string in the sans face does not have the same width.
        let sansNarrow = FontCache.shared.shape("ii", font: font).width
        let sansWide = FontCache.shared.shape("WW", font: font).width
        #expect(sansNarrow < sansWide)
    }

    @Test("Text becomes one bitmap with the glyphs drawn in it")
    func textDrawsPixels() {
        let items = bitmaps(Text("Hello").font(font).foregroundColor(.white),
                            width: 200, height: 40)
        #expect(items.count == 1)
        guard let (bitmap, _, _) = items.first else { return }
        #expect(bitmap.isOpaque == false)
        let covered = bitmap.pixels.count { $0 != 0 }
        #expect(covered > 20, "the glyphs left \(covered) pixels")
        // White text: every drawn pixel has the same value in all channels.
        #expect(bitmap.pixels.allSatisfy { pixel in
            let (alpha, red) = (pixel >> 24, (pixel >> 16) & 0xFF)
            return alpha == red
        })
    }

    @Test("Text uses the foreground colour")
    func textUsesForegroundColor() {
        let items = bitmaps(Text("Hello").font(font).foregroundColor(Color(hex: 0xFF0000)),
                            width: 200, height: 40)
        guard let (bitmap, _, _) = items.first else {
            Issue.record("no bitmap")
            return
        }
        // Red text: the green and the blue channels stay empty.
        #expect(bitmap.pixels.allSatisfy { $0 & 0x0000FFFF == 0 })
        #expect(bitmap.pixels.contains { $0 & 0x00FF0000 != 0 })
    }

    @Test("Text in a row keeps its size and the row grows around it")
    func textInARow() {
        let view = HStack(spacing: 4) {
            Text("Hello").font(font)
            Color.red.frame(width: 10, height: 10)
        }
        let textSize = ViewRenderer.size(of: Text("Hello").font(font), fitting: .unspecified)
        let rowSize = ViewRenderer.size(of: view, fitting: .unspecified)
        #expect(rowSize.width == textSize.width + 4 + 10)
        #expect(rowSize.height == max(textSize.height, 10))
    }
}
