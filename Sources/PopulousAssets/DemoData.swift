/// The data of the animated demo, read from the disk's `populous` program (the
/// title and demo; the game itself is `DAD`). Addresses are those of the program
/// laid out from $10000, as it is analysed in `re/`.
public struct DemoData: Sendable {
    /// One of the sixteen scripted figures ($16D28): the sprite it starts as, and
    /// two values its script's commands use.
    public struct Actor: Sendable {
        public let sprite: Int, cell: Int, aux: Int, flag: Int
        /// Byte-coded script; see `TitleDemo`.
        public let script: [UInt8]
    }

    /// The 10x10 patch of land ($1640C): tile, object and height (in pixels) of
    /// each cell, row by row.
    public let tiles: [Int], objects: [Int], heights: [Int]
    public let actors: [Actor]
    /// Tiles the scripts' "build" commands place ($16E71), and sprites their "pose"
    /// commands show ($16E28).
    public let buildTiles: [Int], poseSprites: [Int]
    /// The 16x32 pieces of the name board ($15A0C): five letters, then the board's
    /// left end, middle and right end; and which letter goes where ($16E98).
    public let letters: [IndexedImage]
    public let letterOrder: [Int]
    /// Two 64x64 pictures that fade in at the top corners ($14026).
    public let logos: [IndexedImage]
    /// The credits, one line at a time ($11DCE).
    public let credits: [[UInt8]]
    /// Fade patterns, three words to a level ($11F62).
    public let dither: [UInt8]
    /// Where the C library's random numbers start ($16F30).
    public let randomSeed: UInt32
    /// The title tune's player data, from the player's base address $12F98 to the
    /// end of the tune: tracks, patterns, instruments and its built-in waveforms.
    public let music: [UInt8]

    static let base = 0x10000

    init(program: [UInt8]) throws {
        let image = try Self.flatten(program)
        func fail(_ reason: String) -> AssetError { .unexpectedFormat(file: "populous", reason: reason) }
        func bytes(_ address: Int, _ count: Int) throws -> [UInt8] {
            let start = address - Self.base
            guard start >= 0, start + count <= image.count else { throw fail("too short for the demo data") }
            return Array(image[start..<start + count])
        }
        func word(_ address: Int) throws -> Int { Int(Int16(bitPattern: try bytes(address, 2).be16(0))) }
        func long(_ address: Int) throws -> Int { Int(try bytes(address, 4).be32(0)) }

        // A check that this is the program the addresses belong to.
        guard try bytes(0x11DCE, 9) == Array("POPULOUS".utf8) + [0] else { throw fail("not the expected program") }

        let map = try bytes(0x1640C, 300)
        tiles = map[0..<100].map(Int.init)
        objects = map[100..<200].map(Int.init)
        // The program multiplies the stored heights by eight when it starts.
        heights = map[200..<300].map { Int(Int8(bitPattern: $0 << 3)) }

        let scripts = try long(0x115F6)
        actors = try (0..<16).map { index in
            let record = 0x16D28 + index * 14
            var script: [UInt8] = []
            var at = try long(scripts + index * 4)
            repeat {
                script += try bytes(at, 1)
                at += 1
            } while script.last != 0xFF && script.count < 4096
            return Actor(
                sprite: try word(record), cell: try word(0x16E08 + index * 2), aux: try word(record + 10),
                flag: try word(record + 12), script: script)
        }
        buildTiles = try bytes(0x16E71, 30).map(Int.init)
        poseSprites = try bytes(0x16E28, 0x16E71 - 0x16E28).map(Int.init)
        letterOrder = try (0..<8).map { try word(0x16E98 + $0 * 2) }

        let letterBytes = Planar.size(width: 16, height: 32, planes: 4, masked: true)
        letters = try (0..<8).map {
            Planar.rowInterleaved(
                try bytes(0x15A0C + $0 * letterBytes, letterBytes), width: 16, height: 32, planes: 4, masked: true)
        }
        // Each row of a logo is four 16-pixel groups of four plane words.
        logos = try (0..<2).map { index in
            let data = try bytes(0x14026 + index * 0x800, 0x800)
            var picture = IndexedImage(width: 64, height: 64)
            for y in 0..<64 {
                for x in 0..<64 {
                    let group = (y * 4 + x >> 4) * 8
                    var value: UInt8 = 0
                    for plane in 0..<4 {
                        let bits = data.be16(group + plane * 2)
                        value |= UInt8((bits >> UInt16(15 - x & 15)) & 1) << UInt8(plane)
                    }
                    picture[x, y] = value
                }
            }
            return picture
        }

        var lines: [[UInt8]] = []
        var at = 0x11DCE
        while lines.count < 64 {
            var line: [UInt8] = []
            while true {
                let byte = try bytes(at, 1)[0]
                at += 1
                if byte == 0 { break }
                line.append(byte)
            }
            lines.append(line)
            if try bytes(at, 1)[0] == 0xFF { break }
        }
        credits = lines
        dither = try bytes(0x11F62, 64)
        randomSeed = UInt32(truncatingIfNeeded: try long(0x16F30))
        music = try bytes(0x12F98, 0x13F92 - 0x12F98)
    }

    /// Lays an AmigaDOS hunk program out as one block, each hunk after the last,
    /// with its addresses fixed up for loading at `base`.
    static func flatten(_ data: [UInt8]) throws -> [UInt8] {
        func fail(_ reason: String) -> AssetError { .unexpectedFormat(file: "populous", reason: reason) }
        var position = 0
        func long() throws -> Int {
            guard position + 4 <= data.count else { throw fail("truncated program") }
            position += 4
            return Int(data.be32(position - 4))
        }
        guard try long() == 0x3F3, try long() == 0 else { throw fail("not an AmigaDOS program") }
        let count = try long()
        _ = try long()
        _ = try long()
        guard (1...16).contains(count) else { throw fail("unexpected number of hunks") }
        let sizes = try (0..<count).map { _ in (try long() & 0x3FFF_FFFF) * 4 }
        let starts = (0..<count).map { sizes[..<$0].reduce(0, +) }
        var image = [UInt8](repeating: 0, count: sizes.reduce(0, +))
        var hunk = 0
        while position < data.count, hunk < count {
            switch try long() & 0x3FFF_FFFF {
            case 0x3E9, 0x3EA:
                let size = try long() * 4
                guard position + size <= data.count, size <= sizes[hunk] else { throw fail("bad hunk size") }
                image.replaceSubrange(starts[hunk]..<starts[hunk] + size, with: data[position..<position + size])
                position += size
            case 0x3EB: _ = try long()
            case 0x3EC:
                while true {
                    let entries = try long()
                    if entries == 0 { break }
                    let target = try long()
                    guard target < count else { throw fail("bad relocation") }
                    for _ in 0..<entries {
                        let at = starts[hunk] + (try long())
                        guard at + 4 <= image.count else { throw fail("bad relocation") }
                        let value = UInt32(truncatingIfNeeded: Int(image.be32(at)) + starts[target] + base)
                        for k in 0..<4 { image[at + k] = UInt8(truncatingIfNeeded: value >> UInt32(24 - k * 8)) }
                    }
                }
            case 0x3F2: hunk += 1
            default: throw fail("unsupported hunk type")
            }
        }
        return image
    }
}
