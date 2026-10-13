/// One entry of the people table, laid out as in the original (22 bytes each).
/// Fields whose purpose is not yet understood keep their offset as a name.
public struct Person: Sendable, Equatable {
    /// Values of `state`. A person on dry land is in exactly one of the first two;
    /// the higher bits mark special conditions.
    public enum State {
        public static let settled: UInt8 = 1
        public static let walking: UInt8 = 2
        public static let fighting: UInt8 = 8
        public static let drowning: UInt8 = 0x10
    }

    public static let byteSize = 22

    public var state: UInt8 = 0
    /// 0 or 1: the side this person belongs to.
    public var owner: UInt8 = 0
    /// How many cells a walker looks ahead (1...4).
    public var byte2: UInt8 = 0
    /// Fighting strength picked up from the last house lived in.
    public var byte3: UInt8 = 0
    /// Strength; the slot is free when this is 0.
    public var life: Int16 = 0
    /// Depends on state: the tick a house was founded, a fight opponent's index, or
    /// a wait counter.
    public var word6: UInt16 = 0
    /// Map cell, `x + y * 64`.
    public var cell: Int16 = 0
    /// Cell offset of the step being taken (e.g. +1, -64, +65), 0 when standing.
    public var direction: Int16 = 0
    /// Animation counter; for a walker, 0...7 through the current step.
    public var frame: Int16 = 0
    /// Non-zero for a knight or other armed person.
    public var long14: Int32 = 0
    public var word18: UInt16 = 0
    public var byte20: UInt8 = 0
    public var byte21: UInt8 = 0

    public init() {}

    /// From the 22-byte record the original stores.
    public init(bytes: [UInt8]) {
        func word(_ o: Int) -> UInt16 { UInt16(bytes[o]) << 8 | UInt16(bytes[o + 1]) }
        state = bytes[0]
        owner = bytes[1]
        byte2 = bytes[2]
        byte3 = bytes[3]
        life = Int16(bitPattern: word(4))
        word6 = word(6)
        cell = Int16(bitPattern: word(8))
        direction = Int16(bitPattern: word(10))
        frame = Int16(bitPattern: word(12))
        long14 = Int32(bitPattern: UInt32(word(14)) << 16 | UInt32(word(16)))
        word18 = word(18)
        byte20 = bytes[20]
        byte21 = bytes[21]
    }

    public var isAlive: Bool { life != 0 }

    /// The record as the original stores it (big-endian).
    public var bytes: [UInt8] {
        func word(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
        let long = UInt32(bitPattern: long14)
        return [state, owner, byte2, byte3]
            + word(UInt16(bitPattern: life)) + word(word6) + word(UInt16(bitPattern: cell))
            + word(UInt16(bitPattern: direction)) + word(UInt16(bitPattern: frame))
            + word(UInt16(long >> 16)) + word(UInt16(long & 0xFFFF))
            + word(word18) + [byte20, byte21]
    }
}

/// One side's record, laid out as in the original (16 bytes each).
public struct Player: Sendable, Equatable {
    /// Index + 1 of this side's leader in the people table, 0 for none.
    public var leader: Int16 = 0
    /// Cell of this side's papal magnet.
    public var magnetCell: Int16 = 32 + 32 * 64
    /// What this side's walkers do: 0 go to the magnet, 1 settle, 2 gather, 3 fight.
    public var mode: Int16 = 1
    /// Houses (not castles) counted this tick.
    public var houses: Int16 = 0
    /// Recounted every tick as the sum of this side's people's life.
    public var population: Int32 = 0
    public var mana: Int32 = 399

    public init() {}

    /// From the 16-byte record the original stores.
    public init(bytes: [UInt8]) {
        func word(_ o: Int) -> Int16 { Int16(bitPattern: UInt16(bytes[o]) << 8 | UInt16(bytes[o + 1])) }
        func long(_ o: Int) -> Int32 { Int32(bitPattern: (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[o + $1]) }) }
        leader = word(0)
        magnetCell = word(2)
        mode = word(4)
        houses = word(6)
        population = long(8)
        mana = long(12)
    }

    public var bytes: [UInt8] {
        func word(_ v: Int16) -> [UInt8] { [UInt8(UInt16(bitPattern: v) >> 8), UInt8(UInt16(bitPattern: v) & 0xFF)] }
        func long(_ v: Int32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - $0 * 8)) } }
        return word(leader) + word(magnetCell) + word(mode) + word(houses) + long(population) + long(mana)
    }
}

extension World {
    /// Slots in the people table; the last two are reserved for flying creatures.
    public static let peopleSlots = 211
    /// Most ordinary people that can exist at once.
    public static let maxPeople = 208
    static let startingLife: Int16 = 45

    /// Adds a walker at a cell ($6378C). With `asLeader`, it becomes its side's leader.
    mutating func createPerson(owner: Int, x: Int, y: Int, asLeader: Bool) {
        guard personCount < Self.maxPeople else { return }
        // The original reuses the current leader's slot here if there is one; that
        // path needs the person-removal routine and is not ported yet. A new world
        // never has a leader at this point.
        precondition(!asLeader || players[owner].leader == 0, "leader replacement is not ported yet")
        let index = personCount
        personCount += 1

        var person = Person()
        person.state = Person.State.walking
        person.owner = UInt8(owner)
        person.byte2 = 1
        person.byte3 = 1
        person.life = Self.startingLife
        person.cell = Int16(x + y * Self.size)
        // The original stores 0xFF and immediately runs the animation step, which
        // wraps a walker's counter past 7 back to 0.
        person.frame = 0
        people[index] = person
        who[Int(person.cell)] = UInt8(index + 1)
        if asLeader { players[owner].leader = Int16(index + 1) }
    }

    /// Places each side's first people ($6400E): the first side on flat land from
    /// the top of the map, the second from the bottom. The last one placed for a
    /// side becomes its leader.
    public mutating func placeStartingPeople(first: Int, second: Int) {
        let cells = Self.size * Self.size
        score += first * 10

        var left = first
        if left > 0 {
            for cell in 0x80..<cells where tile[cell] == Tile.flat {
                left -= 1
                createPerson(owner: 0, x: cell & 63, y: cell >> 6, asLeader: left <= 0)
                if left == 0 { break }
            }
        }
        // Not enough flat land: fall back to any unoccupied dry cell.
        if left != 0 {
            for cell in 0..<cells where tile[cell] != Tile.water && who[cell] == 0 {
                left -= 1
                createPerson(owner: 0, x: cell & 63, y: cell >> 6, asLeader: left <= 0)
                if left == 0 { break }
            }
        }

        left = second
        if left > 0 {
            for cell in stride(from: 0xF80, through: 0x80, by: -1) where tile[cell] == Tile.flat {
                left -= 1
                createPerson(owner: 1, x: cell & 63, y: cell >> 6, asLeader: left <= 0)
                if left == 0 { break }
            }
        }
        if left != 0 {
            // The original starts this scan one cell past the end of the map (reading
            // unrelated memory) and never makes a leader here; the scan starts on the
            // last real cell instead.
            for cell in stride(from: cells - 1, through: 1, by: -1) where tile[cell] != Tile.water && who[cell] == 0 {
                createPerson(owner: 1, x: cell & 63, y: cell >> 6, asLeader: false)
                left -= 1
                if left == 0 { break }
            }
        }
    }
}
