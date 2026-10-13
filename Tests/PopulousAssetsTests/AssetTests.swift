import Foundation
import Testing

@testable import PopulousAssets

/// The disk image is not part of the repository. Tests that need it look for
/// `POPULOUS_ADF`, then for any `.adf` in the package root, and are skipped otherwise.
let diskURL: URL? = {
    if let path = ProcessInfo.processInfo.environment["POPULOUS_ADF"] {
        return URL(fileURLWithPath: path)
    }
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let found = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    return found?.first { $0.pathExtension.lowercased() == "adf" }
}()

func loadVolume() throws -> ADFVolume {
    try ADFVolume(data: [UInt8](try Data(contentsOf: #require(diskURL))))
}

@Suite struct DecoderTests {
    @Test func sequentialPlanes() {
        // 8x1, 2 planes: plane 0 = 10100000, plane 1 = 11000000 -> pixels 3,2,1,0...
        let image = Planar.sequential([0b1010_0000, 0b1100_0000], width: 8, height: 1, planes: 2)
        #expect(image.pixels == [3, 2, 1, 0, 0, 0, 0, 0])
    }

    @Test func maskedRows() {
        // mask 00001111, plane 0 = 11110000 -> four 1s then four transparent.
        let image = Planar.rowInterleaved(
            [0b0000_1111, 0b1111_0000], width: 8, height: 1, planes: 1, masked: true)
        let t = IndexedImage.transparent
        #expect(image.pixels == [1, 1, 1, 1, t, t, t, t])
    }

    @Test func rejectsNonDisk() {
        #expect(throws: AssetError.self) { try ADFVolume(data: [UInt8](repeating: 0, count: 901_120)) }
    }

    @Test func wavHeader() {
        let wav = PCMSample(rate: 8000, samples: [0, -128, 127]).wav()
        #expect(wav.count == 44 + 4)
        #expect(Array(wav[44...]) == [0x80, 0x00, 0xFF, 0x80])
    }
}

@Suite(.enabled(if: diskURL != nil, "needs the Populous ADF"))
struct DiskTests {
    @Test func volume() throws {
        let volume = try loadVolume()
        #expect(volume.name == "Populous")
        #expect(!volume.isFFS)
        #expect(volume.entries.filter { !$0.isDirectory }.count == 36)
        #expect(try volume.contents(of: "dad").count == 131_072)
        #expect(try volume.contents(of: "S/Startup-Sequence") == Array("pop\npopulous\npopulous.prg\n\n".utf8))
    }

    @Test func graphics() throws {
        let assets = try GameAssets(volume: loadVolume())
        #expect(assets.gamePalette.colors.count == 16)
        #expect(assets.gamePalette.colors[1] == .init(r: 0x44, g: 0x44, b: 0x44))
        #expect(assets.title.palette.colors.count == 32)
        #expect(assets.title.image.pixels.allSatisfy { $0 < 32 })
        #expect(assets.mouths.count == 6)
        #expect(assets.landSets.map(\.tiles.count) == [70, 70, 70, 70])
        #expect(assets.sprites.count == 147)
        #expect(assets.largeSprites.count == 13)
        #expect(assets.font.count == 110)
        // Glyph 0 is a space: fully masked out.
        #expect(assets.font[0].pixels.allSatisfy { $0 == IndexedImage.transparent })
        // Tile 0 is a flat diamond: top corners transparent, centre opaque.
        let tile = assets.landSets[0].tiles[0]
        #expect(tile[0, 0] == IndexedImage.transparent)
        #expect(tile[16, 12] != IndexedImage.transparent)
    }

    @Test func levelsAndSound() throws {
        let assets = try GameAssets(volume: loadVolume())
        #expect(assets.nameSyllables.map(\.count) == [32, 32, 32])
        #expect(assets.nameSyllables[0][4] + assets.nameSyllables[1][0] + assets.nameSyllables[2][23] == "HURTOUTORD")
        #expect(assets.levels.count == 99)
        #expect(assets.levels[1].word == 25)
        #expect(assets.effects.map(\.rate) == [10000, 10000, 8000, 8000, 4000, 8000, 5300, 8000])
        #expect(assets.effects[0].samples.count == 21004)
        #expect(assets.music.samples.count == 12)
        #expect(assets.music.grid.count == 64 * MusicFile.patternSize)
        #expect(assets.music.sequence.count == 8)
        #expect(assets.music.patternLengths.count == 64)
        #expect(assets.speech.samples.count == 9)
        #expect(assets.speech.instruments.filter { !$0.isUnused }.count == 10)
    }
}
