/// Amiga bitplane decoders. Widths are always a multiple of 8 pixels.
enum Planar {
    /// Whole planes one after another: all of plane 0, then all of plane 1, ...
    /// Used by the full-screen pictures.
    static func sequential(
        _ data: [UInt8], offset: Int = 0, width: Int, height: Int, planes: Int
    ) -> IndexedImage {
        let rowBytes = width / 8
        var image = IndexedImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                var value: UInt8 = 0
                for plane in 0..<planes {
                    let byte = data[offset + plane * rowBytes * height + y * rowBytes + x >> 3]
                    value |= ((byte >> (7 - UInt8(x & 7))) & 1) << UInt8(plane)
                }
                image[x, y] = value
            }
        }
        return image
    }

    /// Each row stores its planes back to back. With `masked`, the row starts with a
    /// 1-bit mask (set = transparent) ahead of the planes; this is the blitter-ready
    /// layout of the tiles, sprites and font.
    static func rowInterleaved(
        _ data: [UInt8], offset: Int = 0, width: Int, height: Int, planes: Int, masked: Bool
    ) -> IndexedImage {
        let rowBytes = width / 8
        let fields = planes + (masked ? 1 : 0)
        var image = IndexedImage(width: width, height: height)
        for y in 0..<height {
            let row = offset + y * rowBytes * fields
            for x in 0..<width {
                let shift = 7 - UInt8(x & 7)
                if masked, (data[row + x >> 3] >> shift) & 1 != 0 {
                    image[x, y] = IndexedImage.transparent
                    continue
                }
                var value: UInt8 = 0
                for plane in 0..<planes {
                    let byte = data[row + (plane + (masked ? 1 : 0)) * rowBytes + x >> 3]
                    value |= ((byte >> shift) & 1) << UInt8(plane)
                }
                image[x, y] = value
            }
        }
        return image
    }

    /// Like masked `rowInterleaved`, but interleaved per 16-pixel word: each row is
    /// `[mask][plane 0]...[plane n]` for the first 16 pixels, then again for the next.
    static func wordInterleaved(
        _ data: [UInt8], offset: Int = 0, width: Int, height: Int, planes: Int
    ) -> IndexedImage {
        let groupBytes = (planes + 1) * 2
        var image = IndexedImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let group = offset + (y * (width / 16) + (x >> 4)) * groupBytes + ((x >> 3) & 1)
                let shift = 7 - UInt8(x & 7)
                if (data[group] >> shift) & 1 != 0 {
                    image[x, y] = IndexedImage.transparent
                    continue
                }
                var value: UInt8 = 0
                for plane in 0..<planes {
                    value |= ((data[group + (plane + 1) * 2] >> shift) & 1) << UInt8(plane)
                }
                image[x, y] = value
            }
        }
        return image
    }

    /// Byte size of one row-interleaved image.
    static func size(width: Int, height: Int, planes: Int, masked: Bool) -> Int {
        width / 8 * height * (planes + (masked ? 1 : 0))
    }

    /// Splits a file that is nothing but equally sized masked images.
    static func strip(
        _ data: [UInt8], file: String, offset: Int = 0, width: Int, height: Int, planes: Int, masked: Bool
    ) throws -> [IndexedImage] {
        let each = size(width: width, height: height, planes: planes, masked: masked)
        let body = data.count - offset
        guard body > 0, body % each == 0 else {
            throw AssetError.unexpectedFormat(
                file: file, reason: "\(body) bytes is not a whole number of \(width)x\(height) images")
        }
        return (0..<body / each).map {
            rowInterleaved(
                data, offset: offset + $0 * each, width: width, height: height, planes: planes, masked: masked)
        }
    }
}
