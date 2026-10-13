/// The conquest game around the worlds: names, scoring and which world comes next.
public enum Conquest {
    /// The last world number; names exist for every fifth number up to it.
    public static let lastWorld = 2470

    /// Three tables of 32 syllables each (start, middle, end), read from the game.
    public struct Names: Sendable {
        public let start: [String], middle: [String], end: [String]

        public init(start: [String], middle: [String], end: [String]) {
            self.start = start
            self.middle = middle
            self.end = end
        }

        /// A world's name ($6961A): three syllables picked by the first random number
        /// of a generator seeded with the world number. World 0 is always GENESIS.
        public func name(ofWorld number: Int) -> String {
            guard number != 0 else { return "GENESIS" }
            return generatedName(seed: number)
        }

        /// The three syllables a seed gives, without the special case for world 0.
        public func generatedName(seed number: Int) -> String {
            var random = GameRandom(seed: UInt16(truncatingIfNeeded: number))
            let code = random.next()
            return start[code & 31] + middle[(code >> 5) & 31] + end[(code >> 10) & 31]
        }

        /// The world a typed name belongs to ($69720), if it is one.
        public func world(named name: String) -> Int? {
            let wanted = name.uppercased()
            if wanted == "GENESIS" { return 0 }
            return stride(from: 0, through: 5000, by: 5).first { self.name(ofWorld: $0) == wanted }
        }
    }

    /// The world to play after conquering `current` with a final score ($691F8):
    /// one step for every 5000 points, plus one, rounded up to a named world.
    /// Returns nil when the last world has just been conquered.
    public static func world(after current: Int, score: Int) -> Int? {
        var next = current + score / 5000 + 1
        if next % 5 != 0 { next += 5 - next % 5 }
        if next > lastWorld { return current == lastWorld ? nil : lastWorld }
        return next
    }
}

extension World {
    /// The human side's final score for this world ($68CA2): what was earned during
    /// play, bonuses for winning more fights, for every power the player lacked and
    /// every power the computer had, and for a fast opponent; ten times over for a win.
    public func finalScore(won: Bool) -> Int {
        var total = score
        if kills[1] < kills[0] { total += 5000 }
        var bit = 8
        while bit < 0x101 {
            if orders[0].abilities & bit == 0 { total += 1000 }
            if orders[1].abilities & bit != 0 { total += 1000 }
            bit <<= 1
        }
        total += (10 - orders[1].period) * 15
        if won { total *= 10 }
        // (Past the upper limit the original stores an unrelated constant, which
        // happens to be a little below it.)
        if total < 500 { total = 500 }
        if total > 0x87A23 { total = 0x7DC12 }
        return total
    }
}

/// The numbers on the score box shown when a world is decided ($68CA2).
public struct ScoreSummary: Sendable, Equatable {
    /// Each pair is the human side, then the other.
    public var battles: (Int, Int)
    public var knights: (Int, Int)
    public var towns: (Int, Int)
    public var castles: (Int, Int)
    public var score: Int

    public static func == (a: ScoreSummary, b: ScoreSummary) -> Bool {
        a.battles == b.battles && a.knights == b.knights && a.towns == b.towns && a.castles == b.castles
            && a.score == b.score
    }
}

extension World {
    public func scoreSummary(won: Bool) -> ScoreSummary {
        var knights = (0, 0), towns = (0, 0), castles = (0, 0)
        func count(_ pair: inout (Int, Int), _ person: Person) {
            if person.owner == 0 { pair.0 += 1 } else { pair.1 += 1 }
        }
        for person in people.prefix(personCount) where person.life != 0 {
            if person.long14 != 0 { count(&knights, person) }
            if person.state == Person.State.settled {
                if person.frame == Self.castleFrame { count(&castles, person) } else { count(&towns, person) }
            }
        }
        return ScoreSummary(
            battles: (Int(kills[0]), Int(kills[1])), knights: knights, towns: towns, castles: castles,
            score: finalScore(won: won))
    }
}

/// The lord who speaks after a conquest ($691F8): which words he says and how his
/// mouth moves. `step` is one pass of the original's loop, four frames long.
public struct LordSpeech: Sendable, Equatable {
    /// Seconds one pass takes on the original's 50 Hz display.
    public static let stepSeconds = 0.08
    /// Spoken words (instruments of `gwords`) for each rank ($739B4), after
    /// "well done"; and the ones for the final victory ($739AA).
    static let rankWords = [[9], [5], [3], [7], [1, 8], [2], [1, 2], [9, 6], [1, 6], [3, 6]]
    static let finalWords = [0, 1, 3, 5, 6]

    /// True after the last world: a different speech, and the lord winks.
    public let final: Bool
    /// 0...9, mortal to eternal god: the world now reached, in 250s.
    public let rank: Int
    /// Mouth picture to show, 0 (closed) to 4.
    public private(set) var mouth = 0
    public private(set) var eyesDrawn = false
    var counter = 0
    var direction = 1
    var nextMouth = 0

    public init(nextWorld: Int?) {
        final = nextWorld == nil
        rank = min(max((nextWorld ?? 0) / 250, 0), 9)
    }

    /// One pass. `idle` says whether the last word has finished; the result is a
    /// word to start saying now, if any.
    public mutating func step(idle: Bool) -> Int? {
        var word: Int?
        let speaking = final ? 10...14 : 10...12
        if speaking.contains(counter) {
            if final {
                if idle {
                    word = Self.finalWords[counter - 10]
                    counter += 1
                }
            } else if counter == 10 {
                word = 0
                counter = 11
            } else if idle {
                let words = Self.rankWords[rank]
                if counter - 11 < words.count { word = words[counter - 11] }
                counter += 1
            }
        } else {
            // Between speeches: wait, mouth shut, then say it all again.
            if counter > (final ? 200 : 250) { counter = 0 }
            if final, counter == 0x10 { eyesDrawn = true }
            counter += 1
            nextMouth = 0
            direction = 1
        }
        mouth = nextMouth
        if !idle || word != nil {
            nextMouth += direction
            if nextMouth >= 4 || nextMouth <= 0 { direction = -direction }
        }
        return word
    }
}
