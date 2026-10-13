/// A full-screen 320x200 picture with the palette it is shown in.
public struct Screen: Sendable {
    public let image: IndexedImage
    public let palette: Palette
}

/// One of the four terrain sets (`land0`...`land3`).
public struct LandSet: Sendable {
    public static let headerSize = 114
    public static let tileWidth = 32
    public static let tileHeight = 24

    /// Per-terrain data that precedes the tile graphics, as the game reads it: one
    /// word, four tables of 11 words, three words, 16 minimap colours, one word.
    /// Only the minimap colours are understood so far; the rest is kept raw.
    public let header: [UInt8]
    /// Minimap colour of the 16 basic land shapes (tile indices 0-15).
    public var minimapColors: [UInt8] { Array(header[96..<112]) }
    /// Isometric land blocks, buildings and scenery, 32x24 each.
    public let tiles: [IndexedImage]

    public var headerWords: [Int] { (0..<48).map { Int(header.be16($0 * 2)) } }

    init(_ data: [UInt8], file: String) throws {
        guard data.count > Self.headerSize else {
            throw AssetError.unexpectedFormat(file: file, reason: "too short")
        }
        header = Array(data[..<Self.headerSize])
        tiles = try Planar.strip(
            data, file: file, offset: Self.headerSize,
            width: Self.tileWidth, height: Self.tileHeight, planes: 4, masked: true)
    }
}

/// One 10-byte record of `level.dat`. World number `n` (0...2474) uses record
/// `n / 25`; the game only names every fifth number, giving its 495 worlds.
public struct LevelRecord: Sendable, Equatable {
    public let bytes: [UInt8]

    /// World rule bits (bit 0: water kills at once; bit 1: swamps stay after use; more unknown).
    public var ruleFlags: Int { Int(bytes[4]) }
    /// Land set, 0...3 (grass, desert, snow, rock).
    public var terrain: Int { Int(bytes[5]) }
    /// People each side starts with: the side placed from the top of the map, then
    /// the side placed from the bottom.
    public var startingPeople: (top: Int, bottom: Int) { (Int(bytes[6]), Int(bytes[7])) }
    /// World-generator seed, before the low three bits of the world number are added.
    public var word: Int { Int(bytes.be16(8)) }
    /// The computer opponent's skill, and the ticks between its moves.
    public var skill: Int { Int(bytes[0]) }
    public var period: Int { Int(bytes[1]) }
    /// Bit masks of the powers the computer and the player may use.
    public var computerPowers: Int { Int(bytes[2]) }
    public var playerPowers: Int { Int(bytes[3]) }

    static let size = 10
}

/// Everything the game loads from its disk, decoded.
/// Text the original keeps in its program image for the end-of-game score box and
/// the "world to conquer" box.
public struct DialogText: Sendable {
    /// One line of a dialog: where it goes inside the box, and a number that is
    /// either the character or the pixel column at which its value is written.
    public struct Line: Sendable {
        public let x: Int, y: Int, column: Int
        public let text: String
    }

    /// Seven lines ($739DC): result, column heads, battles, knights, towns,
    /// castles, score.
    public let score: [Line]
    /// Fifteen lines ($7365A): heading, seven facts about the world, column heads,
    /// then starting population and five powers for each side.
    public let world: [Line]
    /// Words for the world box ($7390C): 4 landscapes, 5 speeds, 5 ratings, 4 land
    /// rules, 2 swamp rules, 2 water rules, yes and no; then for the lord's speech
    /// ten ranks (24...33) and the five phrases it is put together from.
    public let words: [String]
    public let lost: String, won: String, tryAgain: String, newGame: String
    public let startGame: String, noSuchWorld: String

    /// A clickable line of an options dialog: position inside the box, the width
    /// that takes a click, and its characters. Lines with a tick box start with
    /// the box's character (0x80 empty, 0x81 ticked).
    public struct Item: Sendable {
        public let x: Int, y: Int, width: Int
        public let text: [UInt8]
    }

    /// "Options for good/evil" ($73080): heading, nine abilities, then the
    /// aggression and rate sliders with their captions.
    public let sideOptions: [Item]
    /// "Set game options" ($73B1E): heading, then five pairs of alternatives.
    public let gameOptions: [Item]
    /// "Game setup" ($7334C): heading, five pairs of choices, six commands.
    public let setup: [Item]
    public let ok: String, cancel: String, good: String, evil: String

    init(dad: [UInt8]) throws {
        let base = GameAssets.loadAddress
        func string(at address: Int, limit: Int = 80) throws -> String {
            let start = address - base
            guard start >= 0, start < dad.count, let end = dad[start...].firstIndex(of: 0), end - start <= limit,
                dad[start..<end].allSatisfy({ (0x20...0x5A).contains($0) })
            else { throw AssetError.unexpectedFormat(file: "DAD", reason: "dialog text not at the expected offset") }
            return String(decoding: dad[start..<end], as: UTF8.self)
        }
        func lines(at address: Int, count: Int) throws -> [Line] {
            try (0..<count).map {
                let record = address - base + $0 * 0x2E
                guard record >= 0, record + 0x2E <= dad.count else {
                    throw AssetError.unexpectedFormat(file: "DAD", reason: "dialog lines out of range")
                }
                return Line(
                    x: Int(dad.be16(record)), y: Int(dad.be16(record + 2)), column: Int(dad.be16(record + 4)),
                    text: try string(at: address + $0 * 0x2E + 6, limit: 39))
            }
        }
        score = try lines(at: 0x739DC, count: 7)
        world = try lines(at: 0x7365A, count: 15)
        words = try (0..<39).map {
            let pointer = 0x7390C - base + $0 * 4
            guard pointer + 4 <= dad.count else {
                throw AssetError.unexpectedFormat(file: "DAD", reason: "dialog words out of range")
            }
            return try string(at: Int(dad.be32(pointer)))
        }
        func items(at address: Int, count: Int) throws -> [Item] {
            try (0..<count).map {
                let record = address - base + $0 * 0x2E
                guard record >= 0, record + 0x2E <= dad.count,
                    let end = dad[(record + 6)..<(record + 0x2E)].firstIndex(of: 0)
                else { throw AssetError.unexpectedFormat(file: "DAD", reason: "dialog items out of range") }
                return Item(
                    x: Int(dad.be16(record)), y: Int(dad.be16(record + 2)), width: Int(dad.be16(record + 4)),
                    text: Array(dad[(record + 6)..<end]))
            }
        }
        sideOptions = try items(at: 0x73080, count: 14)
        gameOptions = try items(at: 0x73B1E, count: 11)
        setup = try items(at: 0x7334C, count: 17)
        ok = try string(at: 0x73024 + 6)
        cancel = try string(at: 0x73052 + 6)
        good = try string(at: 0x68BD0)
        evil = try string(at: 0x68BD5)
        lost = try string(at: 0x691D8)
        won = try string(at: 0x691DD)
        tryAgain = try string(at: 0x691E1)
        newGame = try string(at: 0x691EE)
        startGame = try string(at: 0x67D66)
        noSuchWorld = try string(at: 0x67D8A)
    }
}

public struct GameAssets: Sendable {
    /// Offset in `DAD` (the game's memory image, loaded at $5E7C4) of the 16-colour
    /// in-game palette.
    static let gamePaletteOffset = 0x14784

    /// Addresses in `DAD`'s memory image of the three tables of 32 string pointers
    /// that world names are built from, and the address the image is loaded at.
    static let nameTables = [0x740E2, 0x741E2, 0x74162]
    static let loadAddress = 0x5E7C4

    static let shieldBlocksAddress = 0x6E43E
    static let shieldBlockCount = 24

    public let gamePalette: Palette
    /// World-name syllables: 32 starts, 32 middles, 32 ends.
    public let nameSyllables: [[String]]

    /// `load.pic`: 32-colour title screen.
    public let title: Screen
    /// `lord.pic`: the between-worlds screen.
    public let lord: Screen
    /// `qaz.pic`: the game board that frames the map views.
    public let board: Screen
    /// `demo.pic`.
    public let demo: Screen
    /// `mouths.pic`: 48x35 overlays for the lord's face (five mouths, then eyes).
    public let mouths: [IndexedImage]

    public let landSets: [LandSet]
    /// `sprites0.dat`: 16x16 people, flags, effects.
    public let sprites: [IndexedImage]
    /// `spr_320.dat`: 32x32 animation frames in the game palette (a frog wizard,
    /// plant creatures, a stone creature). Where the game shows them is not yet known.
    public let largeSprites: [IndexedImage]
    /// `font.dat`: 8x8 glyphs, starting at ASCII space.
    public let font: [IndexedImage]
    /// 16x16 pictures from `DAD` ($6E43E): the two sides' symbols and ten weapons
    /// from bare hands upwards for the top of the shield, then (12...23) the
    /// pieces dialog boxes and their buttons are built from.
    public let shieldBlocks: [IndexedImage]
    /// The title screen's animated demo, from the `populous` program.
    public let demoData: DemoData
    /// The wording and layout of the score and world dialogs, from `DAD`.
    public let dialogs: DialogText

    public let levels: [LevelRecord]

    public let effects: [PCMSample]
    public let music: MusicFile
    public let speech: MusicFile

    public init(volume: ADFVolume) throws {
        let dad = try volume.contents(of: "DAD")
        guard dad.count >= Self.gamePaletteOffset + 32 else {
            throw AssetError.unexpectedFormat(file: "DAD", reason: "too short to hold the game palette")
        }
        let words = (0..<16).map { dad.be16(Self.gamePaletteOffset + $0 * 2) }
        guard words[0] == 0, words.allSatisfy({ $0 < 0x1000 }), Set(words).count == 16 else {
            throw AssetError.unexpectedFormat(file: "DAD", reason: "game palette not at the expected offset")
        }
        let game = Palette(amigaWords: dad, offset: Self.gamePaletteOffset, count: 16)
        gamePalette = game

        nameSyllables = try Self.nameTables.map { table in
            try (0..<32).map { index in
                let pointer = table - Self.loadAddress + index * 4
                guard pointer + 4 <= dad.count else {
                    throw AssetError.unexpectedFormat(file: "DAD", reason: "name table out of range")
                }
                let start = Int(dad.be32(pointer)) - Self.loadAddress
                guard start >= 0, start < dad.count, let end = dad[start...].firstIndex(of: 0), end - start <= 8,
                    dad[start..<end].allSatisfy({ (0x41...0x5A).contains($0) })
                else { throw AssetError.unexpectedFormat(file: "DAD", reason: "world names not at the expected offset") }
                return String(decoding: dad[start..<end], as: UTF8.self)
            }
        }

        func screen(_ name: String, planes: Int, palette: Palette?) throws -> Screen {
            let data = try volume.contents(of: name)
            let bitmap = 40 * 200 * planes
            let colors = 1 << planes
            guard data.count == bitmap + (palette == nil ? colors * 2 : 0) else {
                throw AssetError.unexpectedFormat(file: name, reason: "unexpected size \(data.count)")
            }
            return Screen(
                image: Planar.sequential(data, width: 320, height: 200, planes: planes),
                // Pictures without a shared palette carry their own after the bitmap.
                palette: palette ?? Palette(amigaWords: data, offset: bitmap, count: colors))
        }
        title = try screen("load.pic", planes: 5, palette: nil)
        lord = try screen("lord.pic", planes: 4, palette: nil)
        board = try screen("qaz.pic", planes: 4, palette: game)
        demo = try screen("demo.pic", planes: 4, palette: game)

        mouths = try Planar.strip(
            try volume.contents(of: "mouths.pic"), file: "mouths.pic",
            width: 48, height: 35, planes: 4, masked: false)

        landSets = try (0..<4).map {
            try LandSet(try volume.contents(of: "land\($0)"), file: "land\($0)")
        }
        sprites = try Planar.strip(
            try volume.contents(of: "sprites0.dat"), file: "sprites0.dat",
            width: 16, height: 16, planes: 4, masked: true)
        let frames = try volume.contents(of: "spr_320.dat")
        let frameBytes = Planar.size(width: 32, height: 32, planes: 4, masked: true)
        guard !frames.isEmpty, frames.count % frameBytes == 0 else {
            throw AssetError.unexpectedFormat(file: "spr_320.dat", reason: "not a whole number of 32x32 frames")
        }
        largeSprites = (0..<frames.count / frameBytes).map {
            Planar.wordInterleaved(frames, offset: $0 * frameBytes, width: 32, height: 32, planes: 4)
        }
        font = try Planar.strip(
            try volume.contents(of: "font.dat"), file: "font.dat",
            width: 8, height: 8, planes: 4, masked: true)

        let blockBytes = Planar.size(width: 16, height: 16, planes: 4, masked: false)
        let blocks = Self.shieldBlocksAddress - Self.loadAddress
        guard dad.count >= blocks + Self.shieldBlockCount * blockBytes else {
            throw AssetError.unexpectedFormat(file: "DAD", reason: "too short to hold the shield pictures")
        }
        shieldBlocks = (0..<Self.shieldBlockCount).map {
            Planar.rowInterleaved(dad, offset: blocks + $0 * blockBytes, width: 16, height: 16, planes: 4, masked: false)
        }

        dialogs = try DialogText(dad: dad)
        demoData = try DemoData(program: try volume.contents(of: "populous"))

        let levelData = try volume.contents(of: "level.dat")
        guard !levelData.isEmpty, levelData.count % LevelRecord.size == 0 else {
            throw AssetError.unexpectedFormat(file: "level.dat", reason: "not a whole number of records")
        }
        levels = stride(from: 0, to: levelData.count, by: LevelRecord.size).map {
            LevelRecord(bytes: Array(levelData[$0..<$0 + LevelRecord.size]))
        }

        effects = try SoundBank.parse(try volume.contents(of: "popsam"), file: "popsam")
        music = try MusicFile(try volume.contents(of: "gmusic1"), file: "gmusic1")
        speech = try MusicFile(try volume.contents(of: "gwords"), file: "gwords")
    }
}
