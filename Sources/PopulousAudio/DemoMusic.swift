import PopulousAssets

/// The tune of the title screen's demo, ported from the player in the disk's
/// `populous` program ($13060). Four tracks each step through a list of patterns;
/// a pattern is a string of notes and commands. Instruments 0-7 are the samples of
/// `popsam`; 13-15 are short waveforms in the program, one of them reshaped as it
/// plays. The original runs `tick` on every display frame, 50 times a second.
public struct DemoMusic: Sendable {
    struct Track {
        /// Bit 1: the pitch is sliding. Bit 2: the reshaped waveform is on its way back.
        var flags = 0
        var pattern = 0
        var sequence = 0
        var sequenceOffset = 4
        var wait = 1
        var period = 0
        var slide = 0
        var loopSet = false
        var instrument: Int?
        var vibrato = 0
        var vibratoStart = 0
        var shape = 0
    }

    /// One of the Amiga's four sound channels: it plays `length` bytes from `start`,
    /// then whatever the latch holds by then, over and over.
    struct Voice {
        var latchStart = 0
        var latchLength = 0
        var start = 0
        var length = 0
        var position = 0.0
        var period = 428
        var volume = 0
        var on = false
    }

    // Offsets from the player's base address.
    static let periods = 0x59A
    static let instruments = 0x608
    static let vibratoTables = 0x808
    static let song = 0x86E
    static let silence = 0x39A
    static let waveInstruments = 13

    /// The player data, then the samples of `popsam` one after another.
    var memory: [Int8]
    var sampleStart = [Int](repeating: 0, count: 16)
    var sampleWords = [Int](repeating: 0, count: 16)
    var pitch = [Int](repeating: 0, count: 16)
    var tempo = 1
    var tracks = [Track](repeating: Track(), count: 4)
    var voices = [Voice](repeating: Voice(), count: 4)
    var framesToTick = 0.0

    public init(data: DemoData, samples: [PCMSample]) {
        memory = data.music.map { Int8(bitPattern: $0) }
        let image = data.music
        func word(_ offset: Int) -> Int { Int(image[offset]) << 8 | Int(image[offset + 1]) }
        func long(_ offset: Int) -> Int { word(offset) << 16 | word(offset + 2) }
        for (index, sample) in samples.prefix(8).enumerated() {
            sampleStart[index] = memory.count
            sampleWords[index] = sample.samples.count / 2
            // The original divides the NTSC clock by the sample's rate.
            pitch[index] = (0x369E99 / max(sample.rate, 1)) & 0xFFFF
            memory += sample.samples
        }
        for index in 0..<3 {
            let instrument = Self.waveInstruments + index
            sampleStart[instrument] = long(0x5FC + index * 4)
            sampleWords[instrument] = word(Self.instruments + instrument * 32 + 8)
            pitch[instrument] = word(Self.instruments + instrument * 32 + 0xC)
        }
        tempo = Int(image[Self.song + 1])
        for index in 0..<4 {
            tracks[index].sequence = long(Self.song + 2 + index * 4)
            tracks[index].pattern = long(tracks[index].sequence)
        }
    }

    func byte(_ offset: Int) -> Int { memory.indices.contains(offset) ? Int(UInt8(bitPattern: memory[offset])) : 0x84 }
    func word(_ offset: Int) -> Int { byte(offset) << 8 | byte(offset + 1) }
    func long(_ offset: Int) -> Int { word(offset) << 16 | word(offset + 2) }
    func field(_ instrument: Int, _ offset: Int) -> Int { word(Self.instruments + instrument * 32 + offset) }

    /// One pass of the player.
    public mutating func tick() {
        for index in (0..<4).reversed() {
            var track = tracks[index]
            defer { tracks[index] = track }

            // The pass after a note starts, say what follows its first run-through.
            if !track.loopSet {
                track.loopSet = true
                if let instrument = track.instrument {
                    let loop = long(Self.instruments + instrument * 32 + 4)
                    if loop == 0 {
                        voices[index].latchStart = Self.silence
                        voices[index].latchLength = 0x200
                    } else if loop < 0x8000_0000 {
                        voices[index].latchStart = sampleStart[instrument] + loop
                        voices[index].latchLength = (sampleWords[instrument] - (loop & 0xFFFF) / 2) * 2
                    }
                }
            }

            track.wait -= 1
            if track.wait != 0 {
                // Cut the note off one pass before the next begins.
                if track.wait == 1 { voices[index].on = false }
                effects(index, &track)
                continue
            }

            track.flags = 0
            var steps = 0
            commands: while steps < 4096 {
                steps += 1
                let command = byte(track.pattern)
                track.pattern += 1
                switch command {
                case 0x80:
                    let instrument = byte(track.pattern) & 15
                    track.pattern += 1
                    track.instrument = instrument
                    track.vibratoStart = Self.vibratoTables + field(instrument, 0x12)
                    track.vibrato = track.vibratoStart
                case 0x81:
                    track.slide = Int(Int8(truncatingIfNeeded: byte(track.pattern)))
                    track.pattern += 1
                    track.flags |= 2
                case 0x82:
                    // A rest.
                    track.wait = (byte(track.pattern) * tempo) & 0xFFFF
                    track.pattern += 1
                    voices[index].latchStart = Self.silence
                    voices[index].latchLength = 0x200
                    break commands
                case 0x84:
                    // End of the pattern: on to the track's next, or round again.
                    var entry = track.sequence + track.sequenceOffset
                    track.sequenceOffset += 4
                    if long(entry) == 0 {
                        entry = track.sequence
                        track.sequenceOffset = 4
                    }
                    track.pattern = long(entry)
                case 0..<0x80:
                    // A note: how long, then which.
                    track.wait = (command * tempo) & 0xFFFF
                    let note = byte(track.pattern)
                    track.pattern += 1
                    guard let instrument = track.instrument else { break commands }
                    track.shape = field(instrument, 0x16)
                    track.vibrato = track.vibratoStart
                    track.period = (word(Self.periods + note * 2) * pitch[instrument]) >> 10 & 0xFFFF
                    voices[index].latchStart = sampleStart[instrument]
                    voices[index].latchLength = sampleWords[instrument] * 2
                    voices[index].volume = min(field(instrument, 0xE), 64)
                    voices[index].period = track.period
                    if !voices[index].on {
                        voices[index].on = true
                        voices[index].start = voices[index].latchStart
                        voices[index].length = voices[index].latchLength
                        voices[index].position = 0
                    }
                    track.loopSet = false
                    break commands
                default:
                    break
                }
            }
            if track.wait == 0 { track.wait = 0x10000 }
        }
    }

    /// Pitch slide, vibrato and the changing waveform, on passes between notes.
    mutating func effects(_ index: Int, _ track: inout Track) {
        guard let instrument = track.instrument else { return }
        if track.flags & 2 != 0 {
            track.period = (track.period + track.slide) & 0xFFFF
            voices[index].period = track.period
        }
        let depth = field(instrument, 0x10)
        if depth != 0 {
            var value = byte(track.vibrato)
            track.vibrato += 1
            if value == 0x84 {
                value = byte(track.vibratoStart)
                track.vibrato = track.vibratoStart + 1
            }
            let step = Int(Int8(truncatingIfNeeded: value)) * (track.period / depth)
            voices[index].period = (track.period + step) & 0xFFFF
        }
        let most = field(instrument, 0x14)
        guard most != 0 else { return }
        let least = field(instrument, 0x16)
        var at = track.shape
        var high = false
        if track.flags & 4 == 0 {
            at += 1
            if at > most {
                track.flags |= 4
                high = true
            }
        } else {
            at -= 1
            if at > least { high = true } else { track.flags &= ~4 }
        }
        let cell = sampleStart[instrument] + at
        if memory.indices.contains(cell) { memory[cell] = high ? 0x3C : 0 }
        track.shape = at
    }

    /// Renders the next `frames` stereo frames, running the player at 50 Hz.
    /// Channels 0 and 3 are on the left, 1 and 2 on the right.
    public mutating func render(
        left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, sampleRate: Double
    ) {
        let framesPerTick = sampleRate / 50
        for frame in 0..<frames {
            if framesToTick <= 0 {
                tick()
                framesToTick += framesPerTick
            }
            framesToTick -= 1
            var mix: (Float, Float) = (0, 0)
            for index in 0..<4 where voices[index].on && voices[index].length > 0 {
                let cell = voices[index].start + Int(voices[index].position)
                let value = memory.indices.contains(cell) ? Float(memory[cell]) / 128 : 0
                let level = value * Float(voices[index].volume) / 64
                if index == 0 || index == 3 { mix.0 += level } else { mix.1 += level }
                // (A few notes in the tune name a pitch outside the table and get a
                // period of 0, which the Amiga's sound chip takes as its slowest.)
                let period = voices[index].period == 0 ? 0x10000 : max(voices[index].period, 124)
                voices[index].position += Double(MusicFile.paulaClock) / Double(period) / sampleRate
                if Int(voices[index].position) >= voices[index].length {
                    voices[index].position -= Double(voices[index].length)
                    voices[index].start = voices[index].latchStart
                    voices[index].length = voices[index].latchLength
                    if Int(voices[index].position) >= voices[index].length { voices[index].position = 0 }
                }
            }
            left[frame] = mix.0 * 0.5
            right[frame] = mix.1 * 0.5
        }
    }
}
