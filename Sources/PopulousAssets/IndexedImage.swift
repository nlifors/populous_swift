/// 12-bit Amiga colour (0x0RGB) palette.
public struct Palette: Sendable, Equatable {
    public struct Color: Sendable, Equatable {
        public let r, g, b: UInt8
    }

    public let colors: [Color]

    public init(colors: [Color]) {
        self.colors = colors
    }

    /// Reads `count` big-endian 0x0RGB words.
    init(amigaWords data: [UInt8], offset: Int, count: Int) {
        colors = (0..<count).map { i in
            let word = data.be16(offset + i * 2)
            // Each 4-bit gun expands to 8 bits by repeating the nibble.
            return Color(
                r: UInt8((word >> 8) & 15) * 17,
                g: UInt8((word >> 4) & 15) * 17,
                b: UInt8(word & 15) * 17)
        }
    }
}

/// Palette-indexed bitmap. Pixels equal to `transparent` are masked out.
public struct IndexedImage: Sendable, Equatable {
    public static let transparent: UInt8 = 0xFF

    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, fill: UInt8 = 0) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: fill, count: width * height)
    }

    public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Copies `source` in at (`x`, `y`), skipping its transparent pixels.
    public mutating func draw(_ source: IndexedImage, x: Int, y: Int) {
        for sy in 0..<source.height where y + sy >= 0 && y + sy < height {
            for sx in 0..<source.width where x + sx >= 0 && x + sx < width {
                let p = source[sx, sy]
                if p != Self.transparent { self[x + sx, y + sy] = p }
            }
        }
    }

    /// Lays equally sized images out in a grid with a 1-pixel transparent gutter.
    public static func sheet(_ images: [IndexedImage], columns: Int) -> IndexedImage {
        guard let first = images.first else { return IndexedImage(width: 1, height: 1, fill: transparent) }
        let rows = (images.count + columns - 1) / columns
        var out = IndexedImage(
            width: columns * (first.width + 1) - 1,
            height: rows * (first.height + 1) - 1,
            fill: transparent)
        for (i, image) in images.enumerated() {
            out.draw(image, x: (i % columns) * (first.width + 1), y: (i / columns) * (first.height + 1))
        }
        return out
    }

    /// 8-bit RGBA, optionally enlarged by an integer factor; transparent pixels get alpha 0.
    public func rgba(palette: Palette, scale: Int = 1) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4 * scale * scale)
        let stride = width * scale * 4
        for y in 0..<height {
            for x in 0..<width {
                let p = self[x, y]
                guard p != Self.transparent, Int(p) < palette.colors.count else { continue }
                let c = palette.colors[Int(p)]
                for dy in 0..<scale {
                    for dx in 0..<scale {
                        let o = (y * scale + dy) * stride + (x * scale + dx) * 4
                        out[o] = c.r
                        out[o + 1] = c.g
                        out[o + 2] = c.b
                        out[o + 3] = 255
                    }
                }
            }
        }
        return out
    }
}
