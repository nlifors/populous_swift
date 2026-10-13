import AVFoundation
import PopulousAssets
import PopulousAudio

/// Plays the sound driver through the Mac's audio output. The driver is rendered
/// on the audio thread, so everything else reaches it through `update`.
final class AudioOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var driver: SoundDriver
    /// The lord's words (`gwords`); while `speaking`, this plays instead of the game.
    private var speech: SoundDriver
    private var speaking = false
    /// Nothing plays while the title picture is up: the game has not begun.
    private var muted = false
    /// The title demo's tune, while the demo runs.
    private var demoMusic: DemoMusic?
    private let engine = AVAudioEngine()

    init?(music: MusicFile, speech words: MusicFile) {
        driver = SoundDriver(music: music)
        speech = SoundDriver(music: words)
        speech.musicOn = false
        speech.effectsOn = false
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2) else { return nil }
        let source = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count == 2,
                let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            self.lock.lock()
            if self.demoMusic != nil {
                self.demoMusic?.render(left: left, right: right, frames: Int(frameCount), sampleRate: format.sampleRate)
            } else if self.muted {
                for frame in 0..<Int(frameCount) {
                    left[frame] = 0
                    right[frame] = 0
                }
            } else if self.speaking {
                self.speech.render(left: left, right: right, frames: Int(frameCount), sampleRate: format.sampleRate)
            } else {
                self.driver.render(left: left, right: right, frames: Int(frameCount), sampleRate: format.sampleRate)
            }
            self.lock.unlock()
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return nil }
    }

    /// Starts the demo's tune from the beginning, or (nil) stops it.
    func setDemoMusic(_ music: DemoMusic?) {
        lock.lock()
        demoMusic = music
        lock.unlock()
    }

    func setMuted(_ on: Bool) {
        lock.lock()
        muted = on
        lock.unlock()
    }

    /// Switches between the game's sounds and the lord's voice.
    func setSpeaking(_ on: Bool) {
        lock.lock()
        speaking = on
        lock.unlock()
    }

    /// Starts a word on the voice channel if one is given; says whether the voice
    /// was idle beforehand.
    func say(_ word: (Bool) -> Int?) {
        lock.lock()
        if let word = word(speech.isIdle(channel: 2)) { speech.start(instrument: word, channel: 2) }
        lock.unlock()
    }

    func update(_ body: (inout SoundDriver) -> Void) {
        lock.lock()
        body(&driver)
        lock.unlock()
    }
}
