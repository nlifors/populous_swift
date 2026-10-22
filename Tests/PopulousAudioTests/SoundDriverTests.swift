import Foundation
import PopulousAssets
import Testing

@testable import PopulousAudio

let audioDiskURL: URL? = {
    if let path = ProcessInfo.processInfo.environment["POPULOUS_ADF"] { return URL(fileURLWithPath: path) }
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let found = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    return found?.first { $0.pathExtension.lowercased() == "adf" }
}()

@Suite(.enabled(if: audioDiskURL != nil, "needs the Populous ADF"))
struct SoundDriverTests {
    func driver() throws -> SoundDriver {
        let volume = try ADFVolume(data: [UInt8](try Data(contentsOf: #require(audioDiskURL))))
        return SoundDriver(music: try GameAssets(volume: volume).music)
    }

    @Test func sequencerWalksTheSong() throws {
        var driver = try driver()
        // The song is patterns 2-8 and 10, 64 steps each.
        #expect(driver.pattern == 2)
        for _ in 0..<64 { driver.stepSequencer() }
        #expect(driver.pattern == 3)
        #expect(driver.step == 0)
        for _ in 0..<64 * 7 { driver.stepSequencer() }
        #expect(driver.pattern == 2)
    }

    @Test func effectsStartOnTwoChannelsAndRespectLoudness() throws {
        var driver = try driver()
        driver.musicOn = false
        driver.play(effect: SoundDriver.Effect.volcano)
        driver.interrupt()
        #expect(driver.channels[2].isBusy && driver.channels[3].isBusy)
        #expect(!driver.channels[0].isBusy)
        #expect(driver.interruptsPerStep == 40)
        // A quieter instrument does not cut in while the effect is sounding.
        let loud = driver.channels[2].volume
        driver.start(instrument: 0, channel: 2)
        #expect(driver.channels[2].volume == loud)
    }

    @Test func loopedEffectComesToAnEnd() throws {
        var driver = try driver()
        driver.musicOn = false
        driver.play(effect: SoundDriver.Effect.earthquake)
        driver.interrupt()
        #expect(driver.channels[2].queue.count == 2)
        var left = [Float](repeating: 0, count: 44100)
        var right = left
        var seconds = 0
        while driver.channels[2].isBusy, seconds < 30 {
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    driver.render(left: l.baseAddress!, right: r.baseAddress!, frames: l.count, sampleRate: 44100)
                }
            }
            seconds += 1
        }
        // One pass and seven repeats of a 0.7 s rumble.
        #expect(!driver.channels[2].isBusy)
        #expect((5...6).contains(seconds))
    }

    @Test func rendersAudibleBoundedSound() throws {
        var driver = try driver()
        driver.setHeartbeat(own: 100, enemy: 300)
        #expect(driver.beatPeriod == 44)
        var left = [Float](repeating: 0, count: 44100 * 4)
        var right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                driver.render(left: l.baseAddress!, right: r.baseAddress!, frames: l.count, sampleRate: 44100)
            }
        }
        let peak = max(left.map(abs).max()!, right.map(abs).max()!)
        #expect(peak > 0.02)
        #expect(peak <= 1)
    }
}

@Suite(.enabled(if: audioDiskURL != nil, "needs the Populous ADF"))
struct DemoMusicTests {
    @Test func tuneKeepsToItsData() throws {
        let volume = try ADFVolume(data: [UInt8](try Data(contentsOf: #require(audioDiskURL))))
        let assets = try GameAssets(volume: volume)
        var tune = DemoMusic(data: assets.demoData, samples: assets.effects)
        let tuneBytes = assets.demoData.music.count
        var notes = [0, 0, 0, 0]
        var instruments = Set<Int>()
        var periods = Set<Int>()
        // Ten minutes of passes: every track keeps reading inside the tune, plays
        // notes, and nothing asks for an instrument that has no sound.
        for _ in 0..<30000 {
            let before = tune.tracks.map(\.loopSet)
            tune.tick()
            for index in 0..<4 {
                #expect((0..<tuneBytes).contains(tune.tracks[index].pattern))
                if before[index], !tune.tracks[index].loopSet {
                    notes[index] += 1
                    periods.insert(tune.voices[index].period)
                    if let instrument = tune.tracks[index].instrument { instruments.insert(instrument) }
                }
            }
        }
        #expect(notes.allSatisfy { $0 > 300 })
        #expect(instruments.allSatisfy { $0 < 8 || $0 >= 13 })
        #expect(periods.allSatisfy { $0 == 0 || (100...4000).contains($0) })
        print("demo tune: notes per track \(notes), instruments \(instruments.sorted()), periods \(periods.min() ?? 0)...\(periods.max() ?? 0)")
    }
}
