/// Mono 8-bit signed PCM, as Paula plays it.
public struct PCMSample: Sendable, Equatable {
    public let rate: Int
    public let samples: [Int8]

    /// RIFF/WAVE encoding (8-bit unsigned, mono).
    public func wav() -> [UInt8] {
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) } }
        func le16(_ v: Int) -> [UInt8] { (0..<2).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) } }
        let padded = samples.count + samples.count % 2
        var out: [UInt8] = []
        out += Array("RIFF".utf8) + le32(36 + padded) + Array("WAVEfmt ".utf8)
        out += le32(16) + le16(1) + le16(1) + le32(rate) + le32(rate) + le16(1) + le16(8)
        out += Array("data".utf8) + le32(samples.count)
        out += samples.map { UInt8(bitPattern: $0) ^ 0x80 }
        if samples.count % 2 != 0 { out.append(0x80) }
        return out
    }
}

/// `popsam`: the in-game sound effects, stored as a chain of
/// `[length: u32][rate in Hz: u16][signed 8-bit PCM]` records.
enum SoundBank {
    static func parse(_ data: [UInt8], file: String) throws -> [PCMSample] {
        var out: [PCMSample] = []
        var offset = 0
        while offset < data.count {
            guard offset + 6 <= data.count else {
                throw AssetError.unexpectedFormat(file: file, reason: "truncated sample header at \(offset)")
            }
            let length = Int(data.be32(offset))
            let rate = Int(data.be16(offset + 4))
            let start = offset + 6
            guard length > 0, rate > 0, start + length <= data.count else {
                throw AssetError.unexpectedFormat(file: file, reason: "bad sample record at \(offset)")
            }
            out.append(PCMSample(rate: rate, samples: data[start..<start + length].map { Int8(bitPattern: $0) }))
            offset = start + length
        }
        return out
    }
}

/// `gmusic1` (music and sound effects) and `gwords` (speech): the data of Bullfrog's
/// sequencer. A song is a sequence of patterns; a pattern is four channels of up to
/// 64 steps; a step names an instrument to start on that channel. Sound effects
/// are instruments too, played by number.
public struct MusicFile: Sendable {
    public struct Instrument: Sendable, Equatable {
        /// Paula period; playback rate is `MusicFile.paulaClock / period`.
        public let period: Int
        /// Bytes of the sample to play.
        public let length: Int
        /// 0...64. A louder instrument may cut off a quieter one that is still playing.
        public let volume: Int
        /// Index into `MusicFile.samples`.
        public let sample: Int
        /// If non-zero, after playing once the sample keeps looping from this offset.
        public let loopStart: Int

        public var isUnused: Bool { length == 0 }
    }

    public struct Sample: Sendable, Equatable {
        public let pcm: [Int8]
        /// The directory's second word: the length again for most samples, 0 for the
        /// looped ones. The game pushes it with the loop point but, by a calling
        /// mismatch, never reads it as a repeat count (see `SoundDriver.tailRepeats`).
        public let loopCycles: Int
    }

    /// PAL Paula clock, Hz.
    public static let paulaClock = 3_546_895
    public static let patternSteps = 64
    public static let channels = 4
    /// Bytes per pattern: four channels of 64 steps.
    public static let patternSize = 256

    /// Steps each of the 64 patterns plays before the song moves on.
    public let patternLengths: [Int]
    /// The song: which pattern to play and how many times, in order.
    public let sequence: [(pattern: Int, repeats: Int)]
    /// All patterns back to back. A step holds `0x41 + instrument index`; anything
    /// below that (normally a space) starts nothing.
    public let grid: [UInt8]
    public let instruments: [Instrument]
    public let samples: [Sample]

    /// A sample at the pitch of the first instrument that uses it, for auditioning.
    public func audition(sample index: Int) -> PCMSample {
        let period = instruments.first { !$0.isUnused && $0.sample == index }?.period ?? 428
        return PCMSample(rate: Self.paulaClock / max(period, 1), samples: samples[index].pcm)
    }

    init(_ data: [UInt8], file: String) throws {
        func fail(_ reason: String) -> AssetError { .unexpectedFormat(file: file, reason: reason) }
        var offset = 0
        func need(_ count: Int) throws {
            guard count >= 0, offset + count <= data.count else { throw fail("truncated at offset \(offset)") }
        }

        try need(128 + 2)
        patternLengths = (0..<64).map { Int(data.be16($0 * 2)) }
        offset = 128

        let sequenceCount = Int(data.be16(offset))
        offset += 2
        try need(sequenceCount * 4 + 4)
        sequence = (0..<sequenceCount).map {
            (Int(data.be16(offset + $0 * 4)), Int(data.be16(offset + $0 * 4 + 2)))
        }
        offset += sequenceCount * 4

        let gridLength = Int(data.be32(offset))
        offset += 4
        guard gridLength % Self.patternSize == 0 else { throw fail("grid length \(gridLength) is not whole patterns") }
        try need(gridLength + 2)
        grid = Array(data[offset..<offset + gridLength])
        offset += gridLength

        let instrumentCount = Int(data.be16(offset))
        offset += 2
        try need(instrumentCount * 8 + 2)
        instruments = (0..<instrumentCount).map {
            let o = offset + $0 * 8
            return Instrument(
                period: Int(data.be16(o)), length: Int(data.be16(o + 2)),
                volume: Int(data[o + 4]), sample: Int(data[o + 5]), loopStart: Int(data.be16(o + 6)))
        }
        offset += instrumentCount * 8

        // Directory entries are [length: u16][loop cycles: u16][stale memory pointer: u32].
        let sampleCount = Int(data.be16(offset))
        offset += 2
        try need(sampleCount * 8 + 4)
        let directory = (0..<sampleCount).map {
            (length: Int(data.be16(offset + $0 * 8)), loopCycles: Int(data.be16(offset + $0 * 8 + 2)))
        }
        offset += sampleCount * 8

        let total = Int(data.be32(offset))
        offset += 4
        guard total == directory.reduce(0, { $0 + $1.length }) else {
            throw fail("sample directory does not add up to the PCM block size")
        }
        try need(total)
        var loaded: [Sample] = []
        for entry in directory {
            let pcm = data[offset..<offset + entry.length].map { Int8(bitPattern: $0) }
            loaded.append(Sample(pcm: pcm, loopCycles: entry.loopCycles))
            offset += entry.length
        }
        samples = loaded

        for instrument in instruments where !instrument.isUnused {
            guard instrument.sample < samples.count else { throw fail("instrument uses a missing sample") }
        }
    }
}
