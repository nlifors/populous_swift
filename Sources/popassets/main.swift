import CoreGraphics
import Foundation
import ImageIO
import PopulousAssets
import PopulousAudio
import PopulousCore
import PopulousRender
import UniformTypeIdentifiers

let usage = """
    usage: popassets <command> <disk.adf> [output-dir]

      list     show the files on the disk
      extract  copy the raw files into output-dir
      dump     decode graphics to PNG and sounds to WAV in output-dir
      dialogs  <disk.adf> <output-dir>
               render the score box and the world boxes over a game screen
      tune     <disk.adf> <out.wav> <seconds>
               render the title demo's tune to a stereo WAV file
      demo     <disk.adf> <output-dir>
               render stages of the title screen's animated demo
      music    <disk.adf> <out.wav> <seconds>
               render the in-game music, with a heartbeat, to a stereo WAV file
      frame    <disk.adf> <out.png> <world-number> [view-x view-y [ticks [person]]]
               render the game screen for a generated world, optionally after
               running it for a number of ticks
    """

struct Failure: Error, CustomStringConvertible {
    let description: String
}

func writePNG(_ image: IndexedImage, palette: Palette, scale: Int = 1, to url: URL) throws {
    let width = image.width * scale
    let height = image.height * scale
    let rgba = Data(image.rgba(palette: palette, scale: scale))
    guard
        let provider = CGDataProvider(data: rgba as CFData),
        let cgImage = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw Failure(description: "could not encode \(url.lastPathComponent)") }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw Failure(description: "could not write \(url.path)")
    }
}

func list(_ volume: ADFVolume) {
    print("Volume \"\(volume.name)\" (\(volume.isFFS ? "FFS" : "OFS"))")
    for entry in volume.entries.sorted(by: { $0.path.lowercased() < $1.path.lowercased() }) {
        let size = entry.isDirectory ? "<dir>" : String(entry.size)
        print(size.padding(toLength: 8, withPad: " ", startingAt: 0), entry.path)
    }
}

func extract(_ volume: ADFVolume, to root: URL) throws {
    let files = FileManager.default
    for entry in volume.entries {
        let url = root.appendingPathComponent(entry.path)
        if entry.isDirectory {
            try files.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(volume.contents(of: entry)).write(to: url)
        }
    }
    print("Extracted \(volume.entries.filter { !$0.isDirectory }.count) files to \(root.path)")
}

func dump(_ volume: ADFVolume, to root: URL) throws {
    let assets = try GameAssets(volume: volume)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func png(_ name: String, _ image: IndexedImage, _ palette: Palette, scale: Int = 1) throws {
        try writePNG(image, palette: palette, scale: scale, to: root.appendingPathComponent(name + ".png"))
    }
    func wav(_ name: String, _ sample: PCMSample) throws {
        try Data(sample.wav()).write(to: root.appendingPathComponent(name + ".wav"))
    }

    let game = assets.gamePalette
    try png("title", assets.title.image, assets.title.palette, scale: 2)
    try png("lord", assets.lord.image, assets.lord.palette, scale: 2)
    try png("board", assets.board.image, assets.board.palette, scale: 2)
    try png("demo", assets.demo.image, assets.demo.palette, scale: 2)
    try png("mouths", .sheet(assets.mouths, columns: 6), assets.lord.palette, scale: 2)
    for (i, land) in assets.landSets.enumerated() {
        try png("land\(i)", .sheet(land.tiles, columns: 10), game, scale: 2)
    }
    try png("sprites", .sheet(assets.sprites, columns: 21), game, scale: 3)
    try png("large-sprites", .sheet(assets.largeSprites, columns: 13), game, scale: 3)
    try png("font", .sheet(assets.font, columns: 22), game, scale: 4)

    for (i, effect) in assets.effects.enumerated() {
        try wav("effect\(i)", effect)
    }
    for (name, file) in [("music", assets.music), ("speech", assets.speech)] {
        for i in file.samples.indices {
            try wav("\(name)-sample\(i)", file.audition(sample: i))
        }
    }

    var report = "Populous asset summary\n\n"
    report += "screens: title 32 colours; lord, board, demo 16 colours\n"
    report += "mouths: \(assets.mouths.count) x 48x35\n"
    report += "sprites: \(assets.sprites.count), large sprites: \(assets.largeSprites.count), "
    report += "font glyphs: \(assets.font.count)\n"
    for (i, land) in assets.landSets.enumerated() {
        report += "\nland\(i): \(land.tiles.count) tiles\n  header words: "
        report += land.headerWords.map(String.init).joined(separator: " ")
        report += "\n  header bytes: " + land.header[96...].map(String.init).joined(separator: " ") + "\n"
    }
    report += "\nlevel.dat: \(assets.levels.count) records (8 bytes, then a word)\n"
    for (i, level) in assets.levels.enumerated() {
        let bytes = level.bytes[..<8].map { String($0).padding(toLength: 3, withPad: " ", startingAt: 0) }
        report += "  \(String(i).padding(toLength: 3, withPad: " ", startingAt: 0)) "
        report += bytes.joined(separator: " ") + " \(level.word)\n"
    }
    report += "\neffects (popsam):\n"
    for (i, effect) in assets.effects.enumerated() {
        report += "  \(i): \(effect.samples.count) bytes at \(effect.rate) Hz\n"
    }
    for (name, file) in [("music (gmusic1)", assets.music), ("speech (gwords)", assets.speech)] {
        report += "\n\(name): \(file.grid.count / MusicFile.patternSize) patterns, \(file.samples.count) samples\n"
        report += "  sequence (pattern x repeats): "
        report += file.sequence.map { "\($0.pattern)x\($0.repeats)" }.joined(separator: " ") + "\n"
        for (i, instrument) in file.instruments.enumerated() where !instrument.isUnused {
            report += "  instrument \(i): sample \(instrument.sample) period \(instrument.period) "
            report += "volume \(instrument.volume) loop from \(instrument.loopStart)\n"
        }
        for pattern in 0..<file.grid.count / MusicFile.patternSize {
            for channel in 0..<MusicFile.channels {
                let start = pattern * MusicFile.patternSize + channel * MusicFile.patternSteps
                let cells = file.grid[start..<start + MusicFile.patternSteps]
                guard cells.contains(where: { $0 >= 0x41 }) else { continue }
                let text = cells.map { $0 < 0x41 ? "." : String($0 - 0x41, radix: 36) }
                report += "  pattern \(pattern) channel \(channel) (\(file.patternLengths[pattern]) steps): "
                report += text.joined(separator: " ") + "\n"
            }
        }
    }
    try report.write(to: root.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
    print("Wrote decoded assets to \(root.path)")
}

func renderMusic(_ volume: ADFVolume, arguments: [String]) throws {
    guard let seconds = Int(arguments[3]), (1...600).contains(seconds) else {
        throw Failure(description: "seconds must be 1...600")
    }
    var driver = SoundDriver(music: try GameAssets(volume: volume).music)
    driver.setHeartbeat(own: 100, enemy: 100)
    let rate = 44100
    var left = [Float](repeating: 0, count: rate * seconds)
    var right = left
    left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            driver.render(left: l.baseAddress!, right: r.baseAddress!, frames: l.count, sampleRate: Double(rate))
        }
    }
    // 16-bit stereo RIFF/WAVE.
    func le(_ value: Int, _ bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    let dataSize = left.count * 4
    var out: [UInt8] = Array("RIFF".utf8) + le(36 + dataSize, 4) + Array("WAVEfmt ".utf8)
    out += le(16, 4) + le(1, 2) + le(2, 2) + le(rate, 4) + le(rate * 4, 4) + le(4, 2) + le(16, 2)
    out += Array("data".utf8) + le(dataSize, 4)
    out.reserveCapacity(out.count + dataSize)
    for i in left.indices {
        out += le(Int(max(-1, min(1, left[i])) * 32767), 2)
        out += le(Int(max(-1, min(1, right[i])) * 32767), 2)
    }
    try Data(out).write(to: URL(fileURLWithPath: arguments[2]))
}

func renderTune(_ volume: ADFVolume, arguments: [String]) throws {
    guard let seconds = Int(arguments[3]), (1...600).contains(seconds) else {
        throw Failure(description: "seconds must be 1...600")
    }
    let assets = try GameAssets(volume: volume)
    var tune = DemoMusic(data: assets.demoData, samples: assets.effects)
    let rate = 44100
    var left = [Float](repeating: 0, count: rate * seconds)
    var right = left
    left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            tune.render(left: l.baseAddress!, right: r.baseAddress!, frames: l.count, sampleRate: Double(rate))
        }
    }
    func le(_ value: Int, _ bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    let dataSize = left.count * 4
    var out: [UInt8] = Array("RIFF".utf8) + le(36 + dataSize, 4) + Array("WAVEfmt ".utf8)
    out += le(16, 4) + le(1, 2) + le(2, 2) + le(rate, 4) + le(rate * 4, 4) + le(4, 2) + le(16, 2)
    out += Array("data".utf8) + le(dataSize, 4)
    var peak: Float = 0
    var loud = 0
    for i in left.indices {
        peak = max(peak, abs(left[i]), abs(right[i]))
        if abs(left[i]) > 0.02 || abs(right[i]) > 0.02 { loud += 1 }
        out += le(Int(max(-1, min(1, left[i])) * 32767), 2)
        out += le(Int(max(-1, min(1, right[i])) * 32767), 2)
    }
    try Data(out).write(to: URL(fileURLWithPath: arguments[2]))
    print("peak \(peak), \(loud * 100 / max(left.count, 1))% of frames audible")
}

func frame(_ volume: ADFVolume, arguments: [String]) throws {
    guard let number = Int(arguments[3]), (0..<2475).contains(number) else {
        throw Failure(description: "world number must be 0...2474")
    }
    let assets = try GameAssets(volume: volume)
    let level = assets.levels[number / 25]
    var world = World.conquest(
        seed: World.conquestSeed(worldNumber: number, levelWord: level.word),
        setup: World.Setup(
                skill: level.skill, period: level.period, computerPowers: level.computerPowers,
                playerPowers: level.playerPowers, ruleFlags: level.ruleFlags,
                startingPeople: (level.startingPeople.top, level.startingPeople.bottom)))
    let rules = LandRules(landWords: assets.landSets[level.terrain].headerWords)
    for _ in 0..<(arguments.count > 6 ? Int(arguments[6]) ?? 0 : 0) {
        world.tick(rules: rules)
        world.processOrders()
    }
    // An optional person to follow, so the shield shows their details.
    if arguments.count > 7, let follow = Int(arguments[7]), world.people.indices.contains(follow) {
        world.selectedPerson = follow + 1
    }
    let viewX = arguments.count > 5 ? Int(arguments[4]) ?? 0 : 0
    let viewY = arguments.count > 5 ? Int(arguments[5]) ?? 0 : 0
    let limit = 0...Renderer.maxViewOrigin
    guard limit.contains(viewX), limit.contains(viewY) else {
        throw Failure(description: "view origin must be 0...\(Renderer.maxViewOrigin)")
    }
    let image = Renderer(assets: assets).frame(
        world: world, terrain: level.terrain, viewX: viewX, viewY: viewY, phase: world.phase,
        litIcons: [(6, 1), (4, 3)], litSideIcons: [(0, 3), (0, 4)])
    try writePNG(image, palette: assets.gamePalette, scale: 3, to: URL(fileURLWithPath: arguments[2]))
}

do {
    func dialogs(_ volume: ADFVolume, to folder: URL) throws {
    let assets = try GameAssets(volume: volume)
    let renderer = Renderer(assets: assets)
    let names = Conquest.Names(start: assets.nameSyllables[0], middle: assets.nameSyllables[1], end: assets.nameSyllables[2])
    let world = World.conquest(seed: World.conquestSeed(worldNumber: 0, levelWord: assets.levels[0].word), startingPeople: (3, 3))
    let board = renderer.frame(world: world, terrain: 0, viewX: 0, viewY: 0)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func write(_ name: String, _ draw: (inout IndexedImage) -> [DialogButton]) throws {
        var image = board
        let buttons = draw(&image)
        print(name, buttons.map { "\($0.text) x \($0.x)...\($0.right) y \($0.y)" })
        try writePNG(image, palette: assets.gamePalette, scale: 3, to: folder.appendingPathComponent(name + ".png"))
    }
    try write("score-won") { renderer.drawScore(world.scoreSummary(won: true), won: true, newGame: true, into: &$0) }
    try write("score-lost") { renderer.drawScore(world.scoreSummary(won: false), won: false, newGame: false, into: &$0) }
    for number in [0, 150, 2470] {
        let brief = WorldBrief(name: names.name(ofWorld: number), worldNumber: number, level: assets.levels[number / 25])
        try write("world-\(number)") { renderer.drawWorldBox(brief, into: &$0) }
    }
    for (name, next, mouth) in [("lord", Optional(25), 0), ("lord-speaking", Optional(2000), 3), ("lord-final", nil, 0)] {
        let lines = renderer.lordLines(conquered: next == nil ? 2470 : 0, next: next, names: names)
        print(name, lines)
        try writePNG(
            renderer.lordScreen(lines: lines, mouth: mouth, eyes: next == nil), palette: assets.lord.palette, scale: 3,
            to: folder.appendingPathComponent(name + ".png"))
    }
    try write("options-evil") { renderer.drawOptions(.side(1, .tutorial), into: &$0) }
    try write("options-rules") { renderer.drawOptions(.rules(0x10), into: &$0) }
    try write("options-setup") { renderer.drawOptions(.setup(conquest: false), into: &$0) }
    var entry = WorldBrief(name: "", worldNumber: 0, level: assets.levels[0])
    entry.entry = ("NOWHERE", true, assets.dialogs.noSuchWorld)
    try write("entry") { renderer.drawWorldBox(entry, into: &$0) }
}

func demo(_ volume: ADFVolume, to folder: URL) throws {
    let assets = try GameAssets(volume: volume)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var demo = TitleDemo(assets: assets)
    var screen = demo.step()
    for pass in 1...3000 {
        if [15, 45, 90, 130, 170, 260, 500, 900, 1400, 2000, 3000].contains(pass) {
            try writePNG(screen, palette: assets.gamePalette, scale: 3, to: folder.appendingPathComponent("demo-\(pass).png"))
        }
        screen = demo.step()
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 2 else { throw Failure(description: usage) }
    let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: arguments[1])))
    let volume = try ADFVolume(data: bytes)
    switch (arguments[0], arguments.count) {
    case ("list", 2): list(volume)
    case ("extract", 3): try extract(volume, to: URL(fileURLWithPath: arguments[2]))
    case ("dump", 3): try dump(volume, to: URL(fileURLWithPath: arguments[2]))
    case ("frame", 4), ("frame", 6), ("frame", 7), ("frame", 8): try frame(volume, arguments: arguments)
    case ("dialogs", 3): try dialogs(volume, to: URL(fileURLWithPath: arguments[2]))
    case ("demo", 3): try demo(volume, to: URL(fileURLWithPath: arguments[2]))
    case ("tune", 4): try renderTune(volume, arguments: arguments)
    case ("music", 4): try renderMusic(volume, arguments: arguments)
    default: throw Failure(description: usage)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
