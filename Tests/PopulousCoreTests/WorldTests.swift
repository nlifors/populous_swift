import Testing

@testable import PopulousCore

func fnv(_ bytes: some Sequence<UInt8>) -> UInt64 {
    bytes.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
}

@Suite struct WorldGenerationTests {
    @Test func randomSequence() {
        var random = GameRandom(seed: 0x6302)
        #expect((0..<4).map { _ in random.next() } == [12577, 11936, 30591, 10174])
    }

    /// Reference values come from running the original setup_world in an emulator
    /// (re/scripts/EmulateWorld.java): world number, seed, then FNV-1a hashes of the
    /// altitude (big-endian words), tile, height and object arrays, and the final seed.
    static let reference: [(Int, UInt16, UInt64, UInt64, UInt64, UInt64, UInt16)] = [
        (0, 0x6302, 0xE5F4_CEC5_E4AD_1E7B, 0x4E1D_8D4A_803A_5A53, 0xA9CE_A44D_77D6_88E8, 0x7F96_1149_04D7_E39A, 0x5C85),
        (5, 0x6307, 0x7C3F_AEE1_0A27_15F3, 0xD7A9_DD92_A7DB_B708, 0x1C76_765C_D19B_7429, 0x84DA_9EE6_4A97_643B, 0x2D47),
        (7, 0x6309, 0x9E87_C7AE_4055_A2CE, 0x7C7A_179D_440D_651E, 0x9FF2_CFAD_1FBB_238C, 0x239F_5EB0_E0C0_EF3D, 0x0B45),
        (25, 0x001A, 0xD278_C667_7665_18A5, 0x85E1_A16F_A155_AA65, 0x8F16_074C_4576_349E, 0xBF5C_93AE_A3A1_AD99, 0x1F68),
        (50, 0x0020, 0xAEAD_2FB0_6032_2929, 0x01EA_55FC_CFC3_C12F, 0x955F_001F_E0AF_37FE, 0x0455_3AC5_5EDC_F207, 0x66DD),
        (125, 0x0050, 0x96DB_5220_2B36_6BAD, 0x19D8_CE6F_99A4_CF1A, 0x9B7B_D939_88E7_0A02, 0x5183_0D87_B6D4_4E08, 0x3120),
        (630, 0x0178, 0x1C9B_3D89_7C3D_D52F, 0xD52A_B80D_F831_D029, 0x4211_ABAB_A7C1_19FE, 0x1745_25D5_EDBC_0778, 0x27E1),
        (1000, 0x03E8, 0x2F6C_9FCC_8528_D672, 0x81FF_074B_5A3A_F9AF, 0xB561_7C76_CA39_3A41, 0xDE16_DF24_8C22_8C5E, 0x2552),
        (2470, 0x0A65, 0x7EEC_029F_86F7_8726, 0x340E_F7A7_A983_A76A, 0x56E7_484C_6538_D635, 0x60AB_F708_18EC_AEEB, 0x05D9),
    ]

    @Test(arguments: reference.indices)
    func matchesOriginal(_ index: Int) {
        let (number, seed, altitude, tile, height, object, finalSeed) = Self.reference[index]
        let world = World.generate(seed: seed)
        let words = world.altitude.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        #expect(fnv(words) == altitude, "altitude, world \(number)")
        #expect(fnv(world.tile) == tile, "tile, world \(number)")
        #expect(fnv(world.height) == height, "height, world \(number)")
        #expect(fnv(world.object) == object, "object, world \(number)")
        #expect(world.random.seed == finalSeed, "final seed, world \(number)")
    }

    /// World number, each side's starting people, then hashes of the who-is-where
    /// layer, the people table and both player records, and the people count.
    static let peopleReference: [(Int, Int, Int, UInt64, UInt64, UInt64, Int)] = [
        (0, 3, 3, 0xD886_8233_B55D_5F0C, 0x8632_74B4_AA24_4C60, 0x4219_1069_850E_354E, 6),
        (5, 3, 3, 0x1E71_2A9F_C5AF_9372, 0xB4EC_E07F_1127_ECB1, 0x4219_1069_850E_354E, 6),
        (7, 3, 3, 0x7839_9762_4C81_D19E, 0xB9C8_EC2B_82F1_431F, 0x4219_1069_850E_354E, 6),
        (25, 3, 3, 0x3462_62AF_ECFD_53D4, 0x7FE8_B355_E6BB_5420, 0x4219_1069_850E_354E, 6),
        (50, 2, 2, 0x4EF3_FF2F_AABA_C5C7, 0x3B51_8405_8CAF_7098, 0xB701_744C_D1E2_04DF, 4),
        (125, 3, 3, 0x1FC6_6108_BB63_341A, 0x6445_D883_4997_5F9A, 0x4219_1069_850E_354E, 6),
        (630, 5, 2, 0xCE8A_7828_0067_72DD, 0x232E_B029_B342_B988, 0x4B43_C84A_AE40_367B, 7),
        (1000, 30, 5, 0xD4AC_79C7_3D9F_2159, 0xE899_13CE_7587_7795, 0x6AAF_8FE9_E4ED_978A, 35),
        (2470, 1, 13, 0xA427_1451_4641_C472, 0x5D65_2F81_A278_8D1D, 0x9098_2C8F_8BC4_9AF0, 14),
    ]

    @Test(arguments: peopleReference.indices)
    func startingPeopleMatchOriginal(_ index: Int) {
        let (number, first, second, who, people, players, count) = Self.peopleReference[index]
        let seed = Self.reference[index].1
        let world = World.conquest(seed: seed, startingPeople: (first, second))
        #expect(world.personCount == count, "count, world \(number)")
        #expect(fnv(world.who) == who, "who, world \(number)")
        #expect(fnv(world.people.flatMap(\.bytes)) == people, "people, world \(number)")
        #expect(fnv(world.players.flatMap(\.bytes)) == players, "players, world \(number)")
    }

    /// The two order records as the original holds them when these runs start.
    static let startingOrders: [[UInt8]] = [
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 5, 1, 255, 0, 6, 0, 0, 0, 0, 0, 2, 0, 3, 0, 1, 0, 0, 0, 0, 0, 5]
            + [UInt8](repeating: 0, count: 12),
        [0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 10, 0, 7, 0, 10, 0, 0, 0, 0, 0, 2, 0, 5, 0, 0, 0, 0, 0, 0, 0, 1]
            + [UInt8](repeating: 0, count: 12),
    ]

    /// Fingerprints of runs that were checked, dump by dump, against the emulated
    /// original (see OracleTests). World number, seed, then the state after 1000 and
    /// 2000 ticks; level record 0, side 1 computer-run without powers.
    @Test(arguments: [
        (0, UInt16(0x6302), UInt64(0xFD3F_517C_B38E_B8AC), UInt64(0xA6F6_7DE1_34E0_7BCD)),
        (5, 0x6307, 0x1402_E575_7524_9633, 0xE804_9E51_7A3B_5DF4),
        (7, 0x6309, 0x7316_BE29_7E34_B55C, 0x9F7F_1895_9FD5_8101),
    ])
    func longRunStaysPinned(_ number: Int, _ seed: UInt16, _ at1000: UInt64, _ at2000: UInt64) {
        var world = World.conquest(seed: seed, startingPeople: (3, 3))
        world.ruleFlags = 3
        world.orders = Self.startingOrders.map { Orders(bytes: $0) }
        var seen: [UInt64] = []
        for tick in 1...2000 {
            world.tick(rules: land0)
            world.processOrders()
            if tick % 1000 == 0 { seen.append(world.fingerprint) }
        }
        #expect(world.unportedPath == nil)
        #expect(seen == [at1000, at2000], "world \(number)")
    }

    /// A world whose computer side has every divine power (level record 33), set up
    /// the way a real game is, with both sides given 30000 or 200000 mana. In these
    /// runs the computer casts two volcanoes and an earthquake at the lower level,
    /// and Armageddon and floods at the higher.
    @Test(arguments: [(Int32(30_000), UInt64(0xECC7_3439_B4C0_3EF0)), (200_000, 0xD309_71DB_8FF9_17E0)])
    func computerPowersStayPinned(_ mana: Int32, _ expected: UInt64) {
        var world = World.conquest(
            seed: 32399,
            setup: World.Setup(
                skill: 10, period: 3, computerPowers: 63, playerPowers: 63, ruleFlags: 16, startingPeople: (3, 3)))
        world.players[0].mana = mana
        world.players[1].mana = mana
        for _ in 1...600 {
            world.tick(rules: land0)
            world.processOrders()
        }
        #expect(world.unportedPath == nil)
        #expect(world.fingerprint == expected)
    }

    @Test func worldNamesAndProgression() {
        // Stand-in syllables that show which table entries a name is built from.
        let names = Conquest.Names(
            start: (0..<32).map { "S\($0)" }, middle: (0..<32).map { "M\($0)" }, end: (0..<32).map { "E\($0)" })
        #expect(names.name(ofWorld: 0) == "GENESIS")
        // World 5's generator gives 23556: start 4, middle 0, end 23.
        #expect(names.name(ofWorld: 5) == "S4M0E23")
        #expect(names.world(named: "s4m0e23") == 5)
        #expect(names.world(named: "NOSUCHWORLD") == nil)

        #expect(Conquest.world(after: 0, score: 500) == 5)
        #expect(Conquest.world(after: 0, score: 5000) == 5)
        #expect(Conquest.world(after: 0, score: 21000) == 5)
        #expect(Conquest.world(after: 0, score: 25000) == 10)
        #expect(Conquest.world(after: 2465, score: 500_000) == 2470)
        #expect(Conquest.world(after: 2470, score: 500) == nil)
    }

    @Test func finalScore() {
        var world = World.conquest(
            seed: 1,
            setup: World.Setup(skill: 5, period: 4, computerPowers: 0b000101, playerPowers: 0b111111, ruleFlags: 0, startingPeople: (3, 3)))
        // 30 for the starting people, 2 x 1000 for the computer's powers, (10 - 4) x 15.
        #expect(world.finalScore(won: false) == 30 + 2000 + 90)
        #expect(world.finalScore(won: true) == 21200)
        world.kills = [3, 1]
        #expect(world.finalScore(won: false) == 30 + 2000 + 90 + 5000)
    }

    @Test func saveGameRoundTrips() throws {
        var world = World.conquest(
            seed: 32399,
            setup: World.Setup(skill: 10, period: 3, computerPowers: 63, playerPowers: 63, ruleFlags: 16, startingPeople: (3, 3)))
        world.players[0].mana = 30_000
        world.players[1].mana = 30_000
        for _ in 1...300 {
            world.tick(rules: land0)
            world.processOrders()
        }
        var save = SaveGame(world: world)
        save.worldNumber = 825
        save.levelRecord = [10, 3, 63, 63, 16, 0, 3, 3, 0x7E, 0x8E]
        let bytes = save.bytes
        #expect(bytes.count == SaveGame.byteSize)
        #expect(Array(bytes[..<4]) == [0xFF, 0xFF, 0xB6, 0x15])

        let loaded = try SaveGame(bytes: bytes)
        #expect(loaded.worldNumber == 825)
        #expect(loaded.levelRecord == save.levelRecord)
        #expect(loaded.world.fingerprint == world.fingerprint)
        #expect(loaded.world.personCount == world.personCount)
        #expect(loaded.world.score == world.score)
        #expect(loaded.bytes == bytes)
        #expect(throws: SaveGame.LoadError.self) { try SaveGame(bytes: [UInt8](repeating: 0, count: SaveGame.byteSize)) }

        // Play on from the loaded game and from the original side by side. A load
        // starts with the animation phase and trodden-ground counts cleared, as the
        // original's does, so give the reference the same.
        var reference = world
        reference.phase = 0
        reference.visits = [UInt16](repeating: 0, count: reference.visits.count)
        reference.selectedPerson = 0
        var resumed = loaded.world
        for _ in 1...200 {
            reference.tick(rules: land0)
            reference.processOrders()
            resumed.tick(rules: land0)
            resumed.processOrders()
        }
        #expect(resumed.fingerprint == reference.fingerprint)
    }

    @Test func conquestSeed() {
        #expect(World.conquestSeed(worldNumber: 7, levelWord: 25346) == 0x6309)
    }
}

@Test func lordSaysWellDoneThenTheRank() {
    // Rank 4 (greater being) has two words; the voice is busy for 5 passes a word.
    var speech = LordSpeech(nextWorld: 1000)
    var said: [(pass: Int, word: Int)] = []
    var mouths: [Int] = []
    var busyUntil = 0
    for pass in 0..<40 {
        if let word = speech.step(idle: pass >= busyUntil) {
            said.append((pass, word))
            busyUntil = pass + 5
        }
        mouths.append(speech.mouth)
    }
    #expect(said.map(\.word) == [0, 1, 8])
    #expect(said.map(\.pass) == [10, 15, 20])
    // Shut while waiting, moving through the first two words, shut for the last.
    #expect(Array(mouths[8..<16]) == [0, 0, 0, 1, 2, 3, 4, 3])
    #expect(mouths[21...].allSatisfy { $0 == 0 })

    var last = LordSpeech(nextWorld: nil)
    var words: [Int] = []
    for _ in 0..<30 { if let word = last.step(idle: true) { words.append(word) } }
    #expect(words == [0, 1, 3, 5, 6])
    #expect(last.eyesDrawn)
}

@Test func tutorialAndCustomWorlds() {
    let tutorial = World.tutorial()
    let living = tutorial.people.prefix(tutorial.personCount).filter { $0.life > 0 }
    #expect(living.filter { $0.owner == 0 }.count == 15)
    #expect(living.filter { $0.owner == 1 }.count == 3)
    #expect(tutorial.players[0].mana == 10000)
    #expect(tutorial.options == .tutorial)
    #expect(tutorial == World.tutorial())

    // A custom map comes from its seed alone, and keeps the options it was given.
    var options = World.Options.standard
    options.abilities[1] = 7
    let first = World.custom(seed: 1234, options: options, startingPeople: options.startingPeople)
    let again = World.custom(seed: 1234, options: options, startingPeople: options.startingPeople)
    #expect(first.world == again.world)
    #expect(first.world.options == options)
    #expect(first.world.fingerprint != World.custom(seed: 1235, options: options, startingPeople: (3, 3)).world.fingerprint)
    #expect(World.Options(skill: [4, 5], abilities: [0, 0], period: [0, 0], ruleFlags: 0).startingPeople == (1, 3))
}
