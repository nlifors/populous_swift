/// A box of height corners.
struct CornerBox: Sendable, Equatable {
    var minX = 0, maxX = 0, minY = 0, maxY = 0
}

/// The land of one world: corner heights plus the per-cell layers derived from them.
public struct World: Sendable, Equatable {
    /// Cells per side.
    public static let size = 64
    /// Height corners per side.
    public static let corners = 65
    public static let maxAltitude = 8

    /// Tile indices with special meaning (they index the land-set tile sheet).
    public enum Tile {
        public static let water: UInt8 = 0
        public static let flat: UInt8 = 15
        public static let rock: UInt8 = 47
        public static let firstTree: UInt8 = 50
    }

    /// `corners` x `corners` corner heights, 0...`maxAltitude`.
    public var altitude: [Int16]
    /// Land-set tile of each cell: the slope shape (which corners are raised), 15 for
    /// flat land, +16 for slopes that touch sea level, or 47-49 for rock.
    public var tile: [UInt8]
    /// Base height of each cell.
    public var height: [UInt8]
    /// Overlay tile of each cell (trees 50-52 after generation), 0 for none.
    public var object: [UInt8]

    /// Index + 1 of the person standing on each cell, 0 for nobody.
    public var who: [UInt8]
    /// The people table; only the first `personCount` slots are in use.
    public var people: [Person]
    public var personCount = 0
    public var players = [Player(), Player()]
    /// How often each cell has been walked over; walkers prefer fresh ground.
    public var visits: [UInt16]
    /// Both sides' order records. They start zeroed; a game sets them up.
    public var orders = [Orders(bytes: [UInt8](repeating: 0, count: Orders.byteSize)), Orders(bytes: [UInt8](repeating: 0, count: Orders.byteSize))]
    /// Game ticks so far.
    public var tick: UInt16 = 0
    /// Flips between 0 and 1 every tick; drives two-frame animation and mana.
    public var phase = 0
    /// Index + 1 of the person the player is following, 0 for none.
    public var selectedPerson = 0
    /// Number of the sound effect the last event asked for, 0 for none. The game's
    /// sound driver plays it and clears this.
    public var pendingSound = 0
    /// Points the human side (side 0) has earned so far in this world.
    public var score = 0
    /// Fights won by each side.
    public var kills: [UInt16] = [0, 0]
    /// The side that has been wiped out, once one has. The world keeps running; it
    /// is up to the game to stop.
    public var defeatedSide: Int?
    /// Whether the computer chooses divine powers; off only to compare against
    /// reference runs made without that routine.
    public var computerUsesPowers = true
    /// Set by the Armageddon power: nobody settles any more, both magnets sit in the
    /// middle of the map and everyone marches there to fight it out.
    public var armageddon = false
    /// World rule bits from the level record.
    public var ruleFlags = 0
    /// Set when the simulation reaches behaviour that has not been ported yet; the
    /// world stops advancing rather than diverge from the original silently.
    public internal(set) var unportedPath: String?
    // Scratch values the original keeps in globals between routines.
    var flatLandSeen = false
    var castlePartsSeen = 0
    var splitScratch = 0
    var changedCorners = 0
    var changedBox = CornerBox()

    /// Cells holding the two papal magnets (drawn as the ankh and the skull). Both
    /// start in the middle of the map.
    public var ankhCell = 32 + 32 * World.size
    public var skullCell = 32 + 32 * World.size

    public var random: GameRandom

    public init(random: GameRandom) {
        altitude = [Int16](repeating: 0, count: Self.corners * Self.corners)
        tile = [UInt8](repeating: 0, count: Self.size * Self.size)
        height = tile
        object = tile
        who = tile
        visits = [UInt16](repeating: 0, count: World.size * World.size)
        people = [Person](repeating: Person(), count: World.peopleSlots)
        self.random = random
    }

    /// A hash of everything the simulation has verified against the original: people,
    /// players, the land layers and the random seed. Used by tests to pin behaviour.
    public var fingerprint: UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ bytes: some Sequence<UInt8>) {
            for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
        }
        mix(people.flatMap(\.bytes))
        mix(players.flatMap(\.bytes))
        mix(altitude.flatMap { [UInt8(truncatingIfNeeded: $0 >> 8), UInt8(truncatingIfNeeded: $0)] })
        mix(tile)
        mix(height)
        mix(object)
        mix(who)
        mix([UInt8(random.seed >> 8), UInt8(random.seed & 0xFF)])
        return hash
    }

    /// Seed of a conquest world: the level record's word plus the low bits of the
    /// world number. The record for world `n` is number `n / 25` in `level.dat`.
    public static func conquestSeed(worldNumber: Int, levelWord: Int) -> UInt16 {
        UInt16(truncatingIfNeeded: levelWord + (worldNumber & 7))
    }

    /// What a level record says about a conquest world, with the human on side 0.
    public struct Setup: Sendable {
        /// The computer's skill, and how many ticks pass between its moves.
        public var skill: Int, period: Int
        /// Power bits each side is allowed (as stored in the level record).
        public var computerPowers: Int, playerPowers: Int
        public var ruleFlags: Int
        public var startingPeople: (first: Int, second: Int)
        /// The world's number; the computer starts richer in the later worlds.
        public var worldNumber = 0

        public init(
            skill: Int, period: Int, computerPowers: Int, playerPowers: Int, ruleFlags: Int,
            startingPeople: (first: Int, second: Int), worldNumber: Int = 0
        ) {
            self.worldNumber = worldNumber
            self.skill = skill
            self.period = period
            self.computerPowers = computerPowers
            self.playerPowers = playerPowers
            self.ruleFlags = ruleFlags
            self.startingPeople = startingPeople
        }
    }

    /// A complete new conquest world set up for play: land, people, and both sides'
    /// order records (side 0 human, side 1 computer) as `setup_world` leaves them.
    public static func conquest(seed: UInt16, setup: Setup) -> World {
        var world = conquest(seed: seed, startingPeople: setup.startingPeople)
        world.ruleFlags = setup.ruleFlags
        world.orders[0].busy = 1
        world.orders[0].setWord(0xE, setup.playerPowers << 3 | 7)
        world.orders[1].assisted = 1
        world.orders[1].busy = 1
        world.orders[1].setWord(0xC, setup.skill)
        world.orders[1].setWord(0xE, setup.computerPowers << 3 | 7)
        world.orders[1].setWord(0x10, setup.period)
        // Past world 1235 the computer starts with enough mana for an earthquake.
        if setup.worldNumber > 0x4D3 { world.players[1].mana = Power.earthquake.cost + 200 }
        return world
    }

    /// What the player can change in a custom game: each side's abilities, the
    /// computer's aggression and rate (stored as skill and period, 10 minus what
    /// the dialog shows), and the rules of the land.
    public struct Options: Sendable, Equatable {
        /// Indexed by side. Ability bits: 1 modify land, 2 attack towns, 4 attack
        /// leader, then earthquake 8, swamp 0x10, knight 0x20, volcano 0x40, flood
        /// 0x80, Armageddon 0x100.
        public var skill: [Int], abilities: [Int], period: [Int]
        /// 1 water is fatal, 2 swamps bottomless, 4 cannot build, 8 only build up,
        /// 0x10 build near towns.
        public var ruleFlags: Int

        public init(skill: [Int], abilities: [Int], period: [Int], ruleFlags: Int) {
            self.skill = skill
            self.abilities = abilities
            self.period = period
            self.ruleFlags = ruleFlags
        }

        /// What the disk's memory image holds for a game not set up from a level
        /// record. (That image is a snapshot of a running game, so these may not
        /// be the values a fresh start has.)
        public static let standard = Options(skill: [5, 8], abilities: [0xFFFF, 0xFFFF], period: [6, 7], ruleFlags: 0x10)
        /// The tutorial's two order records ($72E70, $72E9E) and rule word ($72ECC):
        /// a slow, harmless opponent, and no volcano, flood or Armageddon for you.
        public static let tutorial = Options(skill: [10, 10], abilities: [0x3F, 3], period: [10, 10], ruleFlags: 1)
        /// The landscape the tutorial is always played on ($68BF6).
        public static let tutorialSeed: UInt16 = 0x69BC

        /// Walkers each side starts a custom world with ($6400E).
        public var startingPeople: (first: Int, second: Int) { (skill[0] > 4 ? 3 : 1, skill[1] > 4 ? 3 : 1) }
    }

    /// A custom world as `setup_world` builds one when no conquest world is chosen:
    /// one number is drawn from the seed before the land is made. `nextTerrain`
    /// says whether that number would move a new map on to the next landscape.
    public static func custom(
        seed: UInt16, options: Options, startingPeople: (first: Int, second: Int)
    ) -> (world: World, nextTerrain: Bool) {
        var random = GameRandom(seed: seed)
        var nextTerrain = false
        if seed != 0 { nextTerrain = random.next() & 1 != 0 }
        var world = conquest(seed: random.seed, startingPeople: startingPeople)
        world.apply(options)
        // One human against the computer.
        world.orders[0].busy = 1
        world.orders[1].assisted = 1
        world.orders[1].busy = 1
        return (world, nextTerrain)
    }

    /// The tutorial ($68BF6, $5F376): its own landscape, fifteen walkers against
    /// three, and mana for a volcano to begin with. The original starts it paused.
    public static func tutorial() -> World {
        var world = custom(seed: Options.tutorialSeed, options: .tutorial, startingPeople: (15, 3)).world
        world.players[0].mana = Power.volcano.cost
        return world
    }

    /// Writes custom-game options into both sides' order records and the rules.
    public mutating func apply(_ options: Options) {
        for side in 0..<2 {
            orders[side].setWord(0xC, options.skill[side])
            orders[side].setWord(0xE, options.abilities[side])
            orders[side].setWord(0x10, options.period[side])
        }
        ruleFlags = options.ruleFlags
    }

    /// The options a world is being played with.
    public var options: Options {
        Options(
            skill: orders.map { $0.word(0xC) }, abilities: orders.map { $0.word(0xE) & 0xFFFF },
            period: orders.map { $0.word(0x10) }, ruleFlags: ruleFlags)
    }

    /// Land, then each side's starting people.
    public static func conquest(seed: UInt16, startingPeople: (first: Int, second: Int)) -> World {
        var world = generate(seed: seed)
        world.placeStartingPeople(first: startingPeople.first, second: startingPeople.second)
        return world
    }

    /// Builds the land exactly as the original `setup_world` ($5EBB6) does for a new
    /// conquest world, without people.
    public static func generate(seed: UInt16) -> World {
        var world = World(random: GameRandom(seed: seed))
        // The original resets both players here, drawing two numbers each for the
        // computer player's patience before any land is made.
        for side in 0..<2 {
            let low = world.random.next() % 3
            world.orders[side].setWord(0x1A, low)
            world.orders[side].setWord(0x18, world.random.next() % 5 + low + 1)
        }

        world.raiseRandomWalk(stepX: 2, stepY: 4)
        world.raiseRandomWalk(stepX: 4, stepY: 2)
        world.raiseRandomWalk(stepX: 3, stepY: 3)
        world.updateTiles(x: 0...Self.size - 1, y: 0...Self.size - 1)
        world.scatterScenery()
        // setup_world bumps the seed once on the way out.
        world.random.seed &+= 1
        return world
    }

    /// Raises land along a random walk until a point reaches height 6 ($5F450).
    mutating func raiseRandomWalk(stepX: Int, stepY: Int) {
        var x = random.next() % 64
        var y = random.next() % 64
        while raise(x: x, y: y) != 6 {
            x += random.next() % (stepX * 2 + 1) - stepX
            y += random.next() % (stepY * 2 + 1) - stepY
            x = min(max(x, 0), 64)
            y = min(max(y, 0), 64)
        }
    }

    /// The eight neighbours of a corner, clockwise from east; the order decides the
    /// shape of plateaus.
    private static let cornerNeighbours = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]

    /// Raises one corner by a step, then any neighbour left more than one step below
    /// it, recursively ($5F4E0). Returns the corner's new height, or 0 off the map.
    @discardableResult
    public mutating func raise(x: Int, y: Int) -> Int {
        guard (0...64).contains(x), (0...64).contains(y) else { return 0 }
        let index = y * Self.corners + x
        guard altitude[index] < Self.maxAltitude else { return Int(altitude[index]) }
        altitude[index] += 1
        for (dx, dy) in Self.cornerNeighbours {
            let nx = x + dx
            let ny = y + dy
            guard (0...64).contains(nx), (0...64).contains(ny) else { continue }
            if altitude[index] - altitude[ny * Self.corners + nx] > 1 {
                raise(x: nx, y: ny)
            }
        }
        noteChanged(x: x, y: y)
        return Int(altitude[index])
    }

    /// Lowers one corner by a step, then any neighbour left more than one step above
    /// it, recursively ($603F2). Returns the corner's new height, or 0 off the map.
    @discardableResult
    public mutating func lower(x: Int, y: Int) -> Int {
        guard (0...64).contains(x), (0...64).contains(y) else { return 0 }
        let index = y * Self.corners + x
        guard altitude[index] != 0 else { return 0 }
        altitude[index] -= 1
        for (dx, dy) in Self.cornerNeighbours {
            let nx = x + dx
            let ny = y + dy
            guard (0...64).contains(nx), (0...64).contains(ny) else { continue }
            if altitude[ny * Self.corners + nx] - altitude[index] > 1 {
                lower(x: nx, y: ny)
            }
        }
        noteChanged(x: x, y: y)
        return Int(altitude[index])
    }

    /// Counts a changed corner and widens the box of corners changed so far.
    private mutating func noteChanged(x: Int, y: Int) {
        changedCorners += 1
        changedBox.minX = min(changedBox.minX, x)
        changedBox.maxX = max(changedBox.maxX, x)
        changedBox.minY = min(changedBox.minY, y)
        changedBox.maxY = max(changedBox.maxY, y)
    }

    /// Recomputes the tiles of every cell touching the corners changed so far.
    mutating func updateChangedTiles() {
        let box = changedBox
        updateTiles(
            x: max(box.minX, 1) - 1...min(box.maxX, 0x3F),
            y: max(box.minY, 1) - 1...min(box.maxY, 0x3F))
    }

    /// Least mana a side needs before it may reshape land.
    static let manaToReshape: Int32 = 10

    /// A side raises (or lowers) the land at a corner ($63A12, $638FC). It costs 10
    /// mana plus 4 for every corner that moved. Returns false if the side cannot
    /// afford it.
    @discardableResult
    public mutating func reshapeLand(owner: Int, x: Int, y: Int, raise raising: Bool) -> Bool {
        // (During Armageddon the original lets raising through without the mana check,
        // and charges for neither.)
        guard players[owner].mana >= Self.manaToReshape || (raising && armageddon) else { return false }
        changedBox = CornerBox(minX: x, maxX: x, minY: y, maxY: y)
        changedCorners = 0
        if raising { raise(x: x, y: y) } else { lower(x: x, y: y) }
        if !armageddon { players[owner].mana -= Int32(changedCorners * 4 + 10) }
        updateChangedTiles()
        return true
    }

    /// Recomputes tile shape and base height for a block of cells from the corner
    /// heights ($5F640).
    public mutating func updateTiles(x xs: ClosedRange<Int>, y ys: ClosedRange<Int>) {
        for x in xs {
            for y in ys {
                let cell = x + y * Self.size
                let corner = x + y * Self.corners
                let c0 = altitude[corner]
                let c1 = altitude[corner + 1]
                let c2 = altitude[corner + Self.corners + 1]
                let c3 = altitude[corner + Self.corners]
                var base = (c0 + c1 + c2 + c3) >> 2
                var shape = UInt8(0)
                if base < c0 { shape += 1 }
                if base < c1 { shape += 2 }
                if base < c2 { shape += 4 }
                if base < c3 { shape += 8 }

                if tile[cell] == Tile.rock, shape != 0 || base != 0 {
                    shape = Tile.rock
                } else {
                    tile[cell] = shape
                }
                if base != 0, shape == 0 {
                    base -= 1
                    shape = Tile.flat
                }
                if base == 0, shape != Tile.flat, shape != 0 {
                    shape += 16
                }
                height[cell] = UInt8(base)
                if tile[cell] == Tile.rock {
                    shape = Tile.rock
                } else {
                    tile[cell] = shape
                }
                if shape == 0 { object[cell] = 0 }
                visits[cell] = 0
            }
        }
    }

    /// Drops 7 clumps of rock and 15 clumps of trees on dry land ($64A18).
    mutating func scatterScenery() {
        for clump in 0..<22 {
            let rocks = clump < 7
            let originX = random.next() % 59
            let originY = random.next() % 59
            for _ in 0..<30 {
                let x = originX + random.next() % 9
                let y = originY + random.next() % 9
                guard x < Self.size, y < Self.size else { continue }
                let cell = x + y * Self.size
                guard tile[cell] != Tile.water, tile[cell] != Tile.rock else { continue }
                let variant = UInt8(random.next() % 3)
                if rocks {
                    tile[cell] = Tile.rock + variant
                } else {
                    object[cell] = Tile.firstTree + variant
                }
            }
        }
    }
}
