import Glibc

/// Writes a picture of the screen, for the tests.
///
/// The bytes go to a second file which is then renamed, so a reader on the
/// host (the picture lands in a shared directory) never sees half a picture.
public enum PPM {
    /// Writes a binary PPM (P6). `pixel` gives 0xRRGGBB for a column and a
    /// row, counting from the top left.
    public static func write(width: Int, height: Int, to path: String,
                             pixel: (Int, Int) -> UInt32) throws(DRMError) {
        let temporary = path + ".part"
        guard let file = fopen(temporary, "wb") else {
            throw .call("fopen", errno: errno)
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let colour = pixel(x, y)
                bytes.append(UInt8((colour >> 16) & 0xFF))
                bytes.append(UInt8((colour >> 8) & 0xFF))
                bytes.append(UInt8(colour & 0xFF))
            }
        }

        let header = "P6\n\(width) \(height)\n255\n"
        var written = header.withCString { fwrite($0, 1, strlen($0), file) == strlen($0) }
        written = written && bytes.withUnsafeBytes {
            fwrite($0.baseAddress, 1, $0.count, file) == $0.count
        }
        fclose(file)
        guard written else {
            unlink(temporary)
            throw .call("fwrite", errno: errno)
        }
        guard rename(temporary, path) == 0 else {
            let err = errno
            unlink(temporary)
            throw .call("rename", errno: err)
        }
    }
}
