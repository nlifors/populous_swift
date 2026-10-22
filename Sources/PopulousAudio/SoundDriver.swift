import PopulousAssets

/// The game's sound, as the original's 50 Hz interrupt drives it ($6C70A): a
/// four-channel sequencer for the music, sound effects played over it, and a
/// heartbeat. It renders to stereo floats; nothing here touches audio hardware.
public struct SoundDriver: Sendable {
    /// Sound-effect instrument numbers the game asks for.
    public enum Effect {
        public static let swampDeath = 0x42
        /// Two alternating clashes while a fight is in view.
        public static let fight = 0x43
        public static let knight = 0x45
        public static let fire = 0x46
        public static let armageddon = 0x49
        public static let flood = 0x4A
        public static let volcano = 0x4B
        public static let earthquake = 0x4C
        public static let magnet = 0x4D
        static let heartbeat = 0x47
        static let heartbeatEcho = 0x48
    }

    /// One Paula channel: what is playing, and what follows it.
    struct Channel: Sendable {
        struct Segment: Sendable {
            var sample: Int
            var start: Int
            var length: Int
            /// Times left to play; 0 means until cut off.
            var cycles: Int
        }

        var queue: [Segment] = []
        var position = 0.0
        var period = 428
        var volume = 0
        var isBusy: Bool { !queue.isEmpty }
    }

    public var musicOn = true
    public var effectsOn = true
    /// Times a looped tail plays after the first pass. The original's play routine
    /// pushes the loop point as two words but its audio write reads a long offset
    /// and then a word count from the slot after it, which nobody filled: the
    /// count is the high word of whatever register A2 held when the interrupt
    /// struck. On a 512K Amiga with the game's tables at $7xxxx that is 7; the
    /// alternative, 0, would loop until cut off, and nothing in the song is loud
    /// enough to cut off the earthquake.
    static let tailRepeats = 7
    /// Interrupts between heartbeats (0 for none), and how long before each beat
    /// its echo sounds. The game sets these from the two populations.
    public var beatPeriod = 0
    public var beatLead = 1

    let music: MusicFile
    var channels = [Channel](repeating: Channel(), count: 4)
    var pendingEffect = 0
    // Sequencer position.
    var sequenceIndex = 0
    var step = 0
    var repeats = 0
    var pattern: Int
    /// Interrupts since the last sequencer step, and how many make a step. An
    /// effect stretches the current step to 40 to make room for itself.
    var interruptCount = 0
    var interruptsPerStep = 10
    var beatCount = 0
    /// Output frames until the next interrupt.
    var framesToInterrupt = 0.0

    public init(music: MusicFile) {
        self.music = music
        pattern = music.sequence.first?.pattern ?? 0
    }

    /// Asks for a sound effect; it starts at the next interrupt. A later request
    /// before then replaces it, as in the original.
    public mutating func play(effect: Int) {
        pendingEffect = effect
    }

    /// Heartbeat pace for the human side's population against the enemy's
    /// ($5ED..): faster the more it is outnumbered, silent when it has nobody.
    public mutating func setHeartbeat(own: Int, enemy: Int) {
        guard own != 0 else {
            beatPeriod = 0
            beatLead = 1
            return
        }
        beatPeriod = max(50 - 2 * (enemy / own), 7)
        beatLead = beatPeriod / 3
    }

    /// Whether a channel has finished what it was playing ($6DC42).
    public func isIdle(channel: Int) -> Bool { !channels[channel].isBusy }

    /// Starts an instrument on a channel ($6D570). A quieter instrument does not
    /// interrupt a louder one that is still sounding.
    public mutating func start(instrument index: Int, channel: Int) {
        guard music.instruments.indices.contains(index), channels.indices.contains(channel) else { return }
        let instrument = music.instruments[index]
        if channels[channel].isBusy, instrument.volume < channels[channel].volume { return }
        channels[channel].queue = []
        channels[channel].volume = instrument.volume
        channels[channel].period = max(instrument.period, 1)
        channels[channel].position = 0
        guard music.samples.indices.contains(instrument.sample) else { return }
        let available = music.samples[instrument.sample].pcm.count
        let length = min(instrument.length, available)
        guard length > 0 else { return }
        channels[channel].queue.append(.init(sample: instrument.sample, start: 0, length: length, cycles: 1))
        if instrument.loopStart != 0, instrument.loopStart < length {
            channels[channel].queue.append(
                .init(
                    sample: instrument.sample, start: instrument.loopStart, length: length - instrument.loopStart,
                    cycles: Self.tailRepeats))
        }
    }

    /// One sequencer step ($6D6CA): start whatever each channel's pattern names,
    /// then move on, to the next pattern in the song when this one ends.
    mutating func stepSequencer() {
        let base = pattern * MusicFile.patternSize + step
        for channel in 0..<MusicFile.channels {
            let cell = base + channel * MusicFile.patternSteps
            guard music.grid.indices.contains(cell) else { continue }
            start(instrument: Int(music.grid[cell]) - 0x41, channel: channel)
        }
        step += 1
        guard music.patternLengths.indices.contains(pattern), music.patternLengths[pattern] == step,
            !music.sequence.isEmpty
        else { return }
        repeats += 1
        step = 0
        // (The repeat count is never reset, exactly as in the original.)
        if repeats >= music.sequence[sequenceIndex].repeats {
            sequenceIndex += 1
            if sequenceIndex == music.sequence.count { sequenceIndex = 0 }
        }
        pattern = music.sequence[sequenceIndex].pattern
    }

    /// What the original does on every vertical-blank interrupt.
    mutating func interrupt() {
        if musicOn {
            interruptCount += 1
            if interruptCount == interruptsPerStep {
                interruptsPerStep = 10
                stepSequencer()
                interruptCount = 0
            }
        }
        guard effectsOn else { return }
        if pendingEffect != 0 {
            interruptsPerStep = 40
            start(instrument: pendingEffect, channel: 2)
            start(instrument: pendingEffect, channel: 3)
            pendingEffect = 0
        } else if beatPeriod != 0 {
            beatCount += 1
            if beatCount < beatPeriod {
                if beatPeriod - beatLead == beatCount { start(instrument: Effect.heartbeatEcho, channel: 0) }
            } else {
                start(instrument: Effect.heartbeat, channel: 0)
                beatCount = 0
            }
        }
    }

    /// Renders the next `frames` stereo frames at `sampleRate`, running interrupts
    /// at 50 Hz along the way. Channels 0 and 3 are on the left, 1 and 2 on the
    /// right, as on the Amiga.
    public mutating func render(
        left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, sampleRate: Double
    ) {
        let framesPerInterrupt = sampleRate / 50
        for frame in 0..<frames {
            if framesToInterrupt <= 0 {
                interrupt()
                framesToInterrupt += framesPerInterrupt
            }
            framesToInterrupt -= 1

            var mix: (Float, Float) = (0, 0)
            for index in channels.indices {
                guard let segment = channels[index].queue.first else { continue }
                let pcm = music.samples[segment.sample].pcm
                let value = Float(pcm[segment.start + Int(channels[index].position)]) / 128
                    * Float(channels[index].volume) / 64
                if index == 0 || index == 3 { mix.0 += value } else { mix.1 += value }

                channels[index].position += Double(MusicFile.paulaClock) / Double(channels[index].period) / sampleRate
                if channels[index].position >= Double(segment.length) {
                    channels[index].position -= Double(segment.length)
                    if segment.cycles == 1 {
                        channels[index].queue.removeFirst()
                        channels[index].position = 0
                    } else if segment.cycles > 1 {
                        channels[index].queue[0].cycles -= 1
                    }
                }
            }
            // Leave headroom for two full-volume channels a side, and bleed a little
            // of each side into the other so headphones are bearable.
            left[frame] = (mix.0 * 0.85 + mix.1 * 0.15) * 0.5
            right[frame] = (mix.1 * 0.85 + mix.0 * 0.15) * 0.5
        }
    }
}
