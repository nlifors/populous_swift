/// Per-terrain rule numbers, read from the head of each land file.
public struct LandRules: Sendable, Equatable {
    /// Life a walker loses with every step.
    public var walkCost: Int
    /// Indexed by house size (0...10): life a household gains every 8 ticks.
    public var lifeGain: [Int]
    /// Indexed by house size: mana its side gains every 8 ticks.
    public var manaGain: [Int]
    /// Indexed by house size: the fighting strength its people carry.
    public var strength: [Int]
    /// Indexed by house size: mana taken from its side when the house falls.
    public var houseValue: [Int]
    /// Mana taken for defeating a walker, a knight and a leader.
    public var walkerValue: Int
    public var knightValue: Int
    public var leaderValue: Int

    /// From the 48 words at the start of a land file: walk cost, four 11-word
    /// tables, then the three bounties.
    public init(landWords words: [Int]) {
        walkCost = words[0]
        lifeGain = Array(words[1..<12])
        manaGain = Array(words[12..<23])
        strength = Array(words[23..<34])
        houseValue = Array(words[34..<45])
        walkerValue = words[45]
        knightValue = words[46]
        leaderValue = words[47]
    }
}

/// One side's 46-byte order record, kept raw: it holds the pending land order, the
/// computer player's working state and pointers to notable houses. Only the fields
/// the people update touches have accessors.
public struct Orders: Sendable, Equatable {
    public static let byteSize = 46
    public var bytes: [UInt8]

    public init(bytes: [UInt8]) {
        precondition(bytes.count == Self.byteSize)
        self.bytes = bytes
    }

    func word(_ offset: Int) -> Int { Int(Int16(bitPattern: UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))) }
    mutating func setWord(_ offset: Int, _ value: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value)
    }
    func long(_ offset: Int) -> Int { (0..<4).reduce(0) { $0 << 8 | Int(bytes[offset + $1]) } }
    mutating func setLong(_ offset: Int, _ value: Int) {
        for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (24 - i * 8)) }
    }

    /// Pending land order (1 = raise, 2 = lower at `x`,`y`).
    public var action: Int { get { Int(bytes[0]) } set { bytes[0] = UInt8(truncatingIfNeeded: newValue) } }
    public var x: Int { get { Int(bytes[1]) } set { bytes[1] = UInt8(truncatingIfNeeded: newValue) } }
    public var y: Int { get { Int(bytes[2]) } set { bytes[2] = UInt8(truncatingIfNeeded: newValue) } }
    /// 1 when the computer looks after this side's land.
    public var assisted: Int { get { word(6) } set { setWord(6, newValue) } }
    /// Non-zero while an order is waiting to be carried out.
    public var busy: Int { get { word(8) } set { setWord(8, newValue) } }
    /// The computer player's skill (0...10); higher builds up longer before attacking.
    var skill: Int { word(0xC) }
    /// What this side may do; bit 0 allows reshaping land, bits 1-2 magnet tactics.
    var abilities: Int { word(0xE) }
    /// The computer acts on this side once every `period` ticks.
    var period: Int { word(0x10) }
    /// Ticks the leader still has to wait at the spot the magnet was sent to.
    var magnetPatience: Int { get { word(0x1C) } set { setWord(0x1C, newValue) } }
    var magnetGoal: Int { get { word(0x1E) } set { setWord(0x1E, newValue) } }
    var castleCount: Int { get { word(0x14) } set { setWord(0x14, newValue) } }
    var houseCount: Int { get { word(0x16) } set { setWord(0x16, newValue) } }
    /// Addresses (in the original's memory) of the other side's best house, the other
    /// side's oldest house, and this side's newest house.
    var bestHouse: Int { get { long(0x22) } set { setLong(0x22, newValue) } }
    var oldestHouse: Int { get { long(0x26) } set { setLong(0x26, newValue) } }
    var newestHouse: Int { get { long(0x2A) } set { setLong(0x2A, newValue) } }
}

extension World {
    /// Rule bits from the level record.
    enum Rule {
        static let waterIsFatal = 1
        static let swampsStay = 2
    }

    /// Offsets to the cell itself, its 4 edge and 4 corner neighbours, then the 16
    /// cells of the ring beyond ($72F8A).
    static let ringOffsets = [
        0, -64, 1, 64, -1, -63, 65, 63, -65,
        -128, 2, 128, -2, -126, 130, 126, -130,
        -127, -62, 66, 129, 127, 62, -66, -129,
    ]
    /// The eight steps clockwise from north ($72F7A).
    static let directionOffsets = [-64, -63, 1, 65, 64, 63, -1, -65]
    /// Direction index for a (dx, dy) of -1...1 each, as `dy + (dx + 1) * 3 + 1` ($72F68).
    static let directionFromDelta = [7, 6, 5, 0, 0, 4, 1, 2, 3]
    /// Opposite direction index ($72F18). The ninth entry is what the original reads
    /// when it runs one past the table.
    static let oppositeDirection = [4, 5, 6, 7, 0, 1, 2, 3, 0]
    /// Object tiles of a castle's nine cells, in ring order ($72FD2).
    static let castleParts: [UInt8] = [42, 44, 43, 44, 43, 41, 41, 41, 41]

    static let swampTile: UInt8 = 53
    static let castleFrame: Int16 = 42
    public static let castleScore = 0xBEA
    static let noStep = 999
    static let lowestMana: Int32 = -250
    /// Address of the people table in the original's memory; house pointers and
    /// knights' targets are stored as addresses to stay comparable with it.
    static let peopleAddress = 0x7476C

    func address(ofPerson index: Int) -> Int { Self.peopleAddress + index * Person.byteSize }

    /// What stops a step from `cell` by `offset` ($6DC60): 0 nothing, 1 the map edge,
    /// 2 rock, 3 water.
    func stepCheck(_ cell: Int, _ offset: Int) -> Int {
        guard offset != 0 else { return 0 }
        let target = cell + offset
        guard target >= 0, target < 0x1000 else { return 1 }
        var dx = offset & 0x3F
        if dx > 3 { dx -= 64 }
        let x = (cell & 0x3F) + dx
        guard x >= 0, x <= 0x3F else { return 1 }
        if tile[target] == Tile.water { return 3 }
        if tile[target] == Tile.rock { return 2 }
        return 0
    }

    /// How good a spot is for a house ($6DCCE): 0 if nobody can live there, else a
    /// score that grows with the free or owned flat land around it, or `castleScore`
    /// when all 17 cells qualify. Also notes whether unclaimed flat land was seen and
    /// how many castle parts surround a castle.
    mutating func landScore(owner: Int, cell: Int) -> Int {
        let ownTile = UInt8(owner + 0x1F)
        var score = 0
        castlePartsSeen = 0
        flatLandSeen = false
        for k in 0..<17 {
            let offset = Self.ringOffsets[k]
            let check = stepCheck(cell, offset)
            if check != 0 {
                if check == 2 { score -= 15 }
                continue
            }
            let target = cell + offset
            if tile[target] == ownTile || tile[target] == Tile.flat {
                if tile[target] != ownTile { flatLandSeen = true }
                if score == 0 { score = 50 }
                score += 15
            } else if k == 0 {
                return 0
            }
            let object = Int(Int8(bitPattern: self.object[target]))
            if k < 9, self.object[cell] == 0x2A, object >= 0x29, object <= 0x2C {
                castlePartsSeen += 1
            } else if k != 0, object > 0x20, object <= 0x2C {
                return 0
            }
        }
        if score < 0x23 { score = 0 }
        if score == 0x131 { score = Self.castleScore }
        return score
    }

    /// `landScore` for drawing: the same number without touching the world.
    public func houseSiteScore(owner: Int, cell: Int) -> Int {
        var copy = self
        return copy.landScore(owner: owner, cell: cell)
    }

    /// Writes or clears a settled person's house and the fields around it ($62A64).
    mutating func updateHouse(_ index: Int, removing: Bool) {
        let person = people[index]
        let cell = Int(person.cell)
        let ownTile = UInt8(Int(person.owner) + 0x1F)

        func clearCastle(_ world: inout World) {
            for k in 0..<25 where world.stepCheck(cell, Self.ringOffsets[k]) != 1 {
                let target = cell + Self.ringOffsets[k]
                world.object[target] = 0
                if world.tile[target] == ownTile { world.tile[target] = Tile.flat }
            }
        }

        if !removing {
            if person.frame == Self.castleFrame {
                for k in 0..<25 where stepCheck(cell, Self.ringOffsets[k]) != 1 {
                    let target = cell + Self.ringOffsets[k]
                    if k < 9 { object[target] = Self.castleParts[k] }
                    if tile[target] == Tile.flat { tile[target] = ownTile }
                }
            } else {
                if object[cell] == 0x2A { clearCastle(&self) }
                for k in 0..<17 where stepCheck(cell, Self.ringOffsets[k]) != 1 {
                    let target = cell + Self.ringOffsets[k]
                    if k < 9 { object[target] = 0 }
                    if tile[target] == Tile.flat { tile[target] = ownTile }
                }
                if tile[cell] == ownTile { object[cell] = UInt8(truncatingIfNeeded: person.frame) }
            }
        } else if object[cell] == 0x2A {
            clearCastle(&self)
        } else {
            for k in 0..<17 where stepCheck(cell, Self.ringOffsets[k]) != 1 {
                let target = cell + Self.ringOffsets[k]
                if k < 9 { object[target] = 0 }
                if tile[target] == ownTile { tile[target] = Tile.flat }
            }
            object[cell] = 0
        }
    }

    /// Moves a side's papal magnet ($64720).
    mutating func setMagnet(owner: Int, cell: Int) {
        players[owner].magnetCell = Int16(cell)
        if owner == 0 { ankhCell = cell } else { skullCell = cell }
    }

    /// Takes a person out of the game ($6281C).
    mutating func removePerson(_ index: Int) {
        let person = people[index]
        people[index].life = 0
        if person.state == Person.State.fighting {
            people[Int(person.word6)].state &= ~Person.State.fighting
        }
        if person.state & Person.State.settled != 0 { updateHouse(index, removing: true) }
        let cell = Int(person.cell)
        if Int(who[cell]) - 1 == index { who[cell] = 0 }
        let previous = cell - Int(person.direction)
        if Int(who[previous]) - 1 == index { who[previous] = 0 }
        let owner = Int(person.owner)
        if Int(players[owner].leader) - 1 == index {
            players[owner].leader = 0
            setMagnet(owner: owner, cell: cell)
        }
        if selectedPerson - 1 == index { selectedPerson = 0 }
    }

    /// Advances a person's animation counter ($628FA). Returns true when a cycle
    /// completes, which for a walker means the step is finished.
    @discardableResult
    mutating func animate(_ index: Int) -> Bool {
        let person = people[index]
        guard person.life != 0 else { return false }
        func cycle(_ world: inout World, from first: Int16, through last: Int16, reset: Bool = true) -> Bool {
            world.people[index].frame += 1
            let frame = world.people[index].frame
            guard frame > last || frame < first else { return false }
            if reset { world.people[index].frame = first }
            return true
        }

        if person.state == Person.State.walking {
            people[index].frame += 1
            if person.frame > 6 {
                people[index].frame = 0
                return true
            }
        } else if person.state & Person.State.drowning != 0 {
            return cycle(&self, from: 0x5D, through: 0x60)
        } else if person.state & Person.State.fighting != 0 {
            let other = people[Int(person.word6)]
            let first: Int16
            if person.long14 == 0 {
                first = other.long14 == 0 ? 0x46 : (other.owner == 0 ? 0x82 : 0x86)
            } else if other.long14 == 0 {
                first = person.owner == 0 ? 0x82 : 0x86
            } else {
                first = 0x8A
            }
            return cycle(&self, from: first, through: first + 2)
        } else if person.state == Person.State.settled {
            let score = landScore(owner: Int(person.owner), cell: Int(person.cell))
            people[index].frame = score < Self.castleScore ? Int16(score * 10 / 0x131 + 0x20) : Self.castleFrame
        } else if person.state & 4 != 0 {
            return cycle(&self, from: 0x55, through: 0x57, reset: false)
        } else if person.state & 0x60 != 0 {
            return cycle(&self, from: 0x65, through: 0x66)
        }
        return false
    }

    /// One side's walker absorbs another of the same side ($626DC).
    mutating func merge(_ index: Int, into other: Int) {
        let owner = Int(people[index].owner)
        let leader = Int(players[owner].leader)
        if people[index].long14 != 0 {
            if people[other].state == Person.State.settled { return }
            people[other].long14 = people[index].long14
        }
        let total = Int(people[other].life) + Int(people[index].life)
        people[other].life = total < 0x7D01 ? Int16(total) : 32000
        if index == leader - 1 { players[owner].leader = Int16(other + 1) }
        if selectedPerson - 1 == index { selectedPerson = other + 1 }
        // The absorber has not been counted yet this tick, so avoid counting twice.
        if index < other { players[owner].population -= Int32(people[index].life) }
        if people[other].byte3 < people[index].byte3 { people[other].byte3 = people[index].byte3 }
        people[index].life = 0
        people[other].state &= 0x9F
        people[other].frame = 0
    }

    /// Two enemies meet and lock into a fight ($632E2).
    mutating func startFight(_ index: Int, with other: Int) {
        people[index].state = Person.State.fighting
        people[other].state = (people[other].state & 7) | Person.State.fighting
        people[index].word6 = UInt16(other)
        people[other].word6 = UInt16(index)
        animate(index)
        animate(other)
        let otherCell = Int(people[other].cell)
        let previous = otherCell - Int(people[other].direction)
        if Int(who[previous]) - 1 == other { who[previous] = 0 }
        if Int(who[otherCell]) - 1 == other { who[otherCell] = 0 }
        if people[other].state & Person.State.settled == 0 {
            people[other].cell = people[index].cell
            who[Int(people[index].cell)] = UInt8(index + 1)
        } else {
            who[otherCell] = UInt8(index + 1)
        }
    }

    /// A walker arrives where a fight is going on and adds its strength to its own
    /// side's fighter ($63414).
    mutating func joinFight(_ index: Int, at other: Int) {
        var ally = other
        if people[index].owner != people[other].owner { ally = Int(people[other].word6) }
        let owner = Int(people[index].owner)
        let total = Int(people[ally].life) + Int(people[index].life)
        people[ally].life = total < 0x7D01 ? Int16(total) : 32000
        if Int(players[owner].leader) - 1 == index { players[owner].leader = Int16(ally + 1) }
        if selectedPerson - 1 == index { selectedPerson = ally + 1 }
        if index < ally { players[owner].population -= Int32(people[index].life) }
        if people[index].long14 != 0 { people[ally].long14 = people[index].long14 }
        if people[ally].byte3 < people[index].byte3 { people[ally].byte3 = people[index].byte3 }
        people[index].life = 0
    }

    /// One round of a fight, run for the fighter who started it ($62CB2). Both
    /// roll; both are hurt, by an amount set by the lower roll and the other's
    /// strength.
    mutating func fightRound(_ index: Int, rules: LandRules) {
        let other = Int(people[index].word6)
        let theirRoll = (random.next() % 3 + 1) * Int(people[other].life)
        let ourRoll = (random.next() % 3 + 1) * Int(people[index].life)
        let lower = min(theirRoll, ourRoll)
        let ourStrength = Int(people[index].byte3)
        let theirStrength = Int(people[other].byte3)
        people[other].life &-= Int16(truncatingIfNeeded: ourStrength * (lower / 100) + 10)
        people[index].life &-= Int16(truncatingIfNeeded: theirStrength * (lower / 100) + 10)
        animate(index)
        animate(other)
        let weDied = people[index].life <= 0
        let theyDied = people[other].life <= 0
        if weDied, theyDied {
            removePerson(other)
            removePerson(index)
        } else if weDied {
            endFight(winner: other, loser: index, rules: rules)
        } else if theyDied {
            endFight(winner: index, loser: other, rules: rules)
        }
    }

    /// Settles a fight ($62E62): the winner celebrates, takes over a beaten house if
    /// the land allows (a knight burns it instead), and mana changes hands.
    mutating func endFight(winner: Int, loser: Int, rules: LandRules) {
        let winnerOwner = Int(people[winner].owner)
        let loserOwner = Int(people[loser].owner)
        let loserTile = UInt8(loserOwner + 0x1F)
        kills[winnerOwner] &+= 1
        func backToPreviousLife(_ world: inout World) {
            world.people[winner].state =
                world.people[winner].state & Person.State.settled != 0 ? Person.State.settled : Person.State.walking
        }

        let gain: Int
        if people[loser].state & Person.State.settled == 0 {
            backToPreviousLife(&self)
            if people[loser].long14 != 0 {
                gain = rules.knightValue
            } else {
                gain = Int(players[loserOwner].leader) - 1 == loser ? rules.leaderValue : rules.walkerValue
            }
        } else {
            people[loser].state = Person.State.settled
            animate(loser)
            let size = Int(people[loser].frame) - 0x20
            gain = (0...10).contains(size) ? rules.houseValue[size] : 100
            if people[winner].long14 == 0 || people[winner].life == 0 {
                updateHouse(loser, removing: true)
                if landScore(owner: winnerOwner, cell: Int(people[winner].cell)) < 1 {
                    backToPreviousLife(&self)
                } else {
                    people[loser].state = Person.State.fighting
                    people[winner].state = Person.State.settled
                    people[winner].word6 = tick
                    animate(winner)
                    updateHouse(winner, removing: false)
                }
            } else {
                // A knight leaves the house in ruins and the fields scorched.
                people[loser].state = 0x80
                people[loser].life = 1
                people[loser].word6 = 0x28
                people[winner].state = Person.State.walking
                let cell = Int(people[loser].cell)
                if object[cell] == 0x2A {
                    // (The original does not check the map edge here.)
                    for k in 0..<25 {
                        let target = cell + Self.ringOffsets[k]
                        guard tile.indices.contains(target) else { continue }
                        if k < 9, k != 0, object[target] > 0x28, object[target] < 0x2D { object[target] += 0x15 }
                        if tile[target] == loserTile { tile[target] = 0x42 }
                    }
                } else {
                    for k in 0..<17 where stepCheck(cell, Self.ringOffsets[k]) == 0 {
                        let target = cell + Self.ringOffsets[k]
                        if tile[target] == loserTile { tile[target] = 0x42 }
                    }
                }
                if object[cell] > 0x1F, object[cell] < 0x2B { object[cell] += 0x15 }
                if Int(who[cell]) - 1 == loser { who[cell] = 0 }
            }
        }

        let winnerCell = Int(people[winner].cell)
        if Int(who[winnerCell]) - 1 == loser || who[winnerCell] == 0 { who[winnerCell] = UInt8(winner + 1) }
        if people[winner].byte20 != 0 {
            orders[winnerOwner].setWord(0x1E, winnerCell)
            orders[winnerOwner].setWord(0x1C, 2)
            people[winner].byte20 -= 1
        }
        if people[loser].byte20 != 0 { orders[loserOwner].setWord(0x1C, 0) }
        people[winner].direction = 0
        people[winner].state |= 4
        people[winner].frame = 0x55
        players[winnerOwner].mana += Int32(gain)
        players[loserOwner].mana -= Int32(gain)
        if players[loserOwner].mana < Self.lowestMana { players[loserOwner].mana = Self.lowestMana }
        if selectedPerson - 1 == loser { selectedPerson = winner + 1 }
        if people[loser].life < 1 { removePerson(loser) }
    }

    /// Corner offsets (dx, dy) searched around a house, nearest rows last ($74262).
    static let assistOffsets: [(Int, Int)] = [-4, -3, 4, 3, -2, 2, -1, 1, 0].flatMap { dx in
        (-4...4).map { (dx, $0) }
    }

    mutating func order(_ owner: Int, _ action: Int, x: Int, y: Int) {
        orders[owner].action = action
        orders[owner].x = x
        orders[owner].y = y
        orders[owner].busy = 1
    }

    /// Looks around a house for land worth evening out and orders one change
    /// ($6504A). The result is kept in the person's `byte20`: 0 when an order was
    /// placed, 1 when nothing needed doing.
    mutating func houseAssist(cell: Int, owner: Int) -> UInt8 {
        guard orders[owner].abilities & 1 != 0, ruleFlags & 4 == 0 else {
            // The original returns the low byte of the order record's address here.
            return UInt8(truncatingIfNeeded: 0x72E14 + owner * Orders.byteSize)
        }
        let x = cell & 0x3F
        let y = cell >> 6
        let here = altitude[x + y * Self.corners]
        for (dx, dy) in Self.assistOffsets {
            let nx = x + dx
            let ny = y + dy
            guard (0...64).contains(nx), (0...64).contains(ny) else { continue }
            // Column or row 64 has no cell; the original reads past the row there,
            // which never matches a rock, ruin or swamp tile in practice.
            let target = nx + ny * Self.size
            let tileThere = target < tile.count ? tile[target] : 0
            let mayLower = ruleFlags & 8 == 0
            if tileThere == Tile.rock, mayLower {
                tile[target] += 1
                order(owner, 2, x: nx, y: ny)
                return 0
            }
            let difference = here - altitude[nx + ny * Self.corners]
            if difference > 0 {
                order(owner, 1, x: nx, y: ny)
                return 0
            }
            if difference < 0 || tileThere == 0x42 || tileThere == Self.swampTile, mayLower {
                order(owner, 2, x: nx, y: ny)
                return 0
            }
        }
        return 1
    }

    /// A walker on sloping ground asks for the odd corner out to be raised or
    /// lowered so the cell becomes flat ($651F8).
    mutating func walkerAssist(cell: Int, owner: Int) {
        guard orders[owner].busy == 0, players[owner].mana > 0x13, players[owner].houses < 0x33,
            orders[owner].abilities & 1 != 0, ruleFlags & 4 == 0
        else { return }
        let x = cell & 0x3F
        let y = cell >> 6
        let corner = x + y * Self.corners
        let sum = Int(altitude[corner]) + Int(altitude[corner + 1])
            + Int(altitude[corner + Self.corners]) + Int(altitude[corner + Self.corners + 1])
        guard sum != 1 else { return }
        for cx in x...x + 1 {
            for cy in y...y + 1 {
                let height = Int(altitude[cx + cy * Self.corners])
                if sum % 4 == 3 {
                    if height == sum / 4 {
                        order(owner, 1, x: cx, y: cy)
                        return
                    }
                } else if sum % 4 == 1, height > sum / 4, ruleFlags & 8 == 0 {
                    order(owner, 2, x: cx, y: cy)
                    return
                }
            }
        }
    }

    /// Cell of the person a stored address points at. A null address reads as cell 0.
    func cell(atAddress address: Int) -> Int {
        let index = (address - Self.peopleAddress) / Person.byteSize
        guard address != 0, people.indices.contains(index) else { return 0 }
        return Int(people[index].cell)
    }

    /// The computer player's standing strategy for a side with no order pending
    /// ($6578C): settle until it has enough houses, then gather on the magnet and
    /// move it towards its newest house, the enemy's best house or the enemy magnet,
    /// depending on how strong its leader is.
    mutating func computerStrategy(_ side: Int) {
        let enemy = side == 0 ? 1 : 0
        let record = orders[side]
        let mode = players[side].mode
        func setMode(_ world: inout World, _ newMode: Int) { world.order(side, 0xE, x: newMode, y: 1) }

        let buildings = Int16(truncatingIfNeeded: record.castleCount + record.houseCount)
        if buildings < Int16(truncatingIfNeeded: record.skill * 2 + 0xF)
            || tick % 0x5A < UInt16(truncatingIfNeeded: record.skill + 10)
        {
            if mode == 0 { setMode(&self, random.next() % 3 + 1) }
            return
        }
        let enemyLeader = players[enemy].leader != 0 ? people[Int(players[enemy].leader) - 1] : nil
        guard players[side].leader != 0 else {
            if mode != 0 {
                setMode(&self, 0)
                orders[side].magnetPatience = 0
            }
            return
        }
        let leader = people[Int(players[side].leader) - 1]
        let magnet = Int(players[side].magnetCell)
        func sendMagnet(_ world: inout World, to goal: Int, remember: Bool) {
            world.order(side, 5, x: goal & 0x3F, y: goal >> 6)
            if remember {
                world.orders[side].magnetGoal = goal
                world.orders[side].magnetPatience = 2
            }
        }

        if Int(leader.cell) == record.magnetGoal, record.magnetPatience != 0 {
            orders[side].magnetPatience -= 1
        }
        let patience = orders[side].magnetPatience
        if leader.life < 6000 {
            // Weak leader: tour the side's own houses to gather strength.
            if patience == 0 {
                let goal = cell(atAddress: record.newestHouse)
                if magnet != goal {
                    sendMagnet(&self, to: goal, remember: true)
                    return
                }
            } else if magnet != record.magnetGoal {
                sendMagnet(&self, to: record.magnetGoal, remember: false)
                return
            }
            if mode != 0 { setMode(&self, 0) }
        } else if enemyLeader == nil || leader.life <= enemyLeader!.life &+ 500 || players[enemy].mode != 0 {
            if record.abilities & 2 != 0 {
                let goal = cell(atAddress: record.bestHouse)
                if magnet == goal || patience != 0 {
                    if mode != 0 { setMode(&self, 0) }
                } else {
                    sendMagnet(&self, to: goal, remember: true)
                }
            }
        } else if record.abilities & 4 != 0 {
            if mode == 0 {
                let goal = Int(players[enemy].magnetCell)
                if magnet != goal { sendMagnet(&self, to: goal, remember: false) }
            } else {
                setMode(&self, 0)
            }
        }
    }

    /// Points a knight at the nearest living enemy, or at himself if there is none
    /// ($62612).
    mutating func retarget(_ index: Int) {
        let me = people[index]
        people[index].long14 = Int32(address(ofPerson: index))
        var nearest = 9999
        for other in 0..<personCount {
            let them = people[other]
            guard them.owner != me.owner, them.life > 0, them.state & 0x80 == 0 else { continue }
            let distance = abs(Int(them.cell & 0x3F) - Int(me.cell & 0x3F)) + abs(Int(them.cell >> 6) - Int(me.cell >> 6))
            if distance < nearest {
                people[index].long14 = Int32(address(ofPerson: other))
                nearest = distance
            }
        }
    }

    /// Mana each power costs ($72FE8 onwards), and the ability bit that allows it.
    public enum Power {
        static let magnetCost: Int32 = 200
        static let earthquake = (cost: Int32(2500), bit: 0x08)
        static let swamp = (cost: Int32(5000), bit: 0x10)
        static let knight = (cost: Int32(7500), bit: 0x20)
        static let volcano = (cost: Int32(10000), bit: 0x40)
        static let flood = (cost: Int32(40000), bit: 0x80)
        static let armageddon = (cost: Int32(80000), bit: 0x100)
    }

    /// Points the human side scores for using a power.
    private mutating func award(_ owner: Int, _ points: Int) {
        if owner == 0 { score += points }
    }

    /// Checks that a side may use a power and can afford it, and takes the mana.
    private mutating func pay(_ owner: Int, _ power: (cost: Int32, bit: Int), evenDuringArmageddon: Bool = false) -> Bool {
        guard players[owner].mana >= power.cost, evenDuringArmageddon || !armageddon,
            orders[owner].abilities & power.bit != 0
        else { return false }
        players[owner].mana -= power.cost
        return true
    }

    /// A corner height read the way the original indexes it, running on into the
    /// tile layer that follows the height table in memory when past the end.
    private func altitudeWord(_ index: Int) -> Int {
        if altitude.indices.contains(index) { return Int(altitude[index]) }
        let byte = (index - altitude.count) * 2
        guard byte >= 0, byte + 1 < tile.count else { return 0 }
        return Int(tile[byte]) << 8 | Int(tile[byte + 1])
    }

    /// Earthquake ($64234): two passes over a 9x9 block of corners, each raised land
    /// corner randomly raised (1 in 5) or lowered (3 in 5).
    mutating func earthquake(owner: Int, x: Int, y: Int) {
        guard pay(owner, Power.earthquake) else { return }
        award(owner, 25)
        pendingSound = 0x4C
        changedBox = CornerBox(minX: x, maxX: x, minY: y, maxY: y)
        for _ in 0..<2 {
            for i in x..<x + 9 {
                for j in y..<y + 9 where altitudeWord(i + j * Self.corners) != 0 {
                    switch random.next() % 5 {
                    case 1: raise(x: i, y: j)
                    case 2, 3, 4: lower(x: i, y: j)
                    default: break
                    }
                }
            }
        }
        updateChangedTiles()
    }

    /// Volcano ($6446C): piles land up in shrinking squares, then strews rock over
    /// the 8x8 cells. (The original means to spare both leaders and both magnets
    /// but looks up the first side's leader twice.)
    mutating func volcano(owner: Int, x: Int, y: Int) {
        guard pay(owner, Power.volcano) else { return }
        award(owner, 100)
        pendingSound = 0x4B
        changedBox = CornerBox(minX: x, maxX: x, minY: y, maxY: y)
        for ring in 0..<5 {
            for i in ring..<9 - ring {
                for j in ring..<9 - ring {
                    let roll = random.next() % 5
                    if roll == 1 || roll == 2 || roll == 4 { raise(x: x + i, y: y + j) }
                }
            }
        }
        let leader = Int(players[0].leader)
        let spared = leader != 0 ? Int(people[leader - 1].cell) : 0
        for i in x..<x + 8 {
            for j in y..<y + 8 where (0..<Self.size).contains(i) && (0..<Self.size).contains(j) {
                let cell = i + j * Self.size
                if random.next() % 5 == 0, cell != spared,
                    cell != Int(players[0].magnetCell), cell != Int(players[1].magnetCell)
                {
                    tile[cell] = Tile.rock
                    object[cell] = 0
                }
            }
        }
        updateChangedTiles()
    }

    /// Swamp ($64756): 30 tries at turning free flat or farmed land near the spot
    /// into swamp, which swallows the next walker to step on it.
    mutating func swamp(owner: Int, x: Int, y: Int) {
        guard pay(owner, Power.swamp) else { return }
        award(owner, 50)
        for _ in 0..<30 {
            let sx = x + random.next() % 7 - 3
            let sy = y + random.next() % 7 - 3
            guard (0..<Self.size).contains(sx), (0..<Self.size).contains(sy) else { continue }
            let cell = sx + sy * Self.size
            if [Tile.flat, 31, 32, 0x42].contains(tile[cell]), who[cell] == 0 { tile[cell] = Self.swampTile }
        }
    }

    /// Knight ($6487E): the leader becomes a knight, hunting the nearest enemy; the
    /// magnet stays where he stood and the side is leaderless.
    mutating func knight(owner: Int) {
        let leader = Int(players[owner].leader) - 1
        guard leader >= 0, pay(owner, Power.knight) else { return }
        award(owner, 150)
        pendingSound = 0x45
        people[leader].byte20 = 1
        retarget(leader)
        setMagnet(owner: owner, cell: Int(people[leader].cell))
        players[owner].leader = 0
    }

    /// Flood ($63F0A): every corner of the world sinks one step.
    mutating func flood(owner: Int) {
        guard pay(owner, Power.flood) else { return }
        award(owner, 250)
        pendingSound = 0x4A
        for index in altitude.indices where altitude[index] > 0 { altitude[index] -= 1 }
        updateTiles(x: 0...Self.size - 1, y: 0...Self.size - 1)
    }

    /// Armageddon ($64982): knights stand down and the final battle begins.
    mutating func startArmageddon(owner: Int) {
        guard pay(owner, Power.armageddon, evenDuringArmageddon: true) else { return }
        award(owner, 5000)
        pendingSound = 0x49
        for index in 0..<personCount { people[index].long14 = 0 }
        armageddon = true
    }

    /// Where the computer aims a volcano or earthquake ($656AA): at an enemy standing
    /// on its magnet if it has no leader, otherwise around the enemy's oldest house.
    private mutating func aim(_ side: Int) {
        if players[side].leader == 0 {
            let magnet = Int(players[side].magnetCell)
            let there = Int(who[magnet])
            if there != 0, Int(people[there - 1].owner) != side {
                orders[side].x = magnet & 0x3F
                orders[side].y = magnet >> 6
                return
            }
        }
        let target = cell(atAddress: orders[side].oldestHouse)
        orders[side].x = max((target & 0x3F) - 3, 0)
        orders[side].y = max((target >> 6) - 3, 0)
    }

    /// The computer's choice of divine power for a side with no order pending
    /// ($653DA), from the grandest it can afford downwards.
    mutating func computerPowers(_ side: Int) {
        let enemy = side == 0 ? 1 : 0
        let record = orders[side]
        let abilities = record.abilities
        let mana = players[side].mana
        let leader = Int(players[side].leader) - 1
        let used = record.word(0x12)

        if abilities & Power.armageddon.bit != 0, mana > Power.armageddon.cost + 999,
            players[side].population > players[enemy].population
        {
            order(side, 0xE, x: record.x, y: 3)
        } else if abilities & Power.flood.bit != 0, mana > Power.flood.cost + 1999 {
            order(side, 0xE, x: record.x, y: 4)
        } else if abilities & Power.knight.bit != 0, leader >= 0, people[leader].life >= 0xBB9 {
            if mana > Power.knight.cost + 500 { order(side, 0xE, x: record.x, y: 5) }
        } else if record.oldestHouse != 0 {
            if mana > Power.volcano.cost + 500, abilities & Power.volcano.bit != 0 {
                orders[side].action = 6
                aim(side)
                orders[side].busy = 1
                orders[side].setWord(0x12, 0)
                return
            }
            if mana > Power.swamp.cost + 500, abilities & Power.swamp.bit != 0,
                record.word(0x1A) <= used || abilities & Power.earthquake.bit == 0,
                used <= record.word(0x18) || abilities & Power.volcano.bit == 0
            {
                let enemyLeader = Int(players[enemy].leader) - 1
                if enemyLeader != -1, leader == -1 || people[leader].life < people[enemyLeader].life {
                    // (The original leaves the side free to give another order.)
                    orders[side].setWord(0x12, used + 1)
                    orders[side].action = 4
                    orders[side].x = Int(people[enemyLeader].cell) & 0x3F
                    orders[side].y = Int(people[enemyLeader].cell) >> 6
                    return
                }
            }
            let oldest = (record.oldestHouse - Self.peopleAddress) / Person.byteSize
            if mana > Power.earthquake.cost + 500, people.indices.contains(oldest),
                people[oldest].state == Person.State.settled, abilities & Power.earthquake.bit != 0,
                used < record.word(0x1A) || abilities & (Power.swamp.bit | Power.volcano.bit) == 0
            {
                orders[side].action = 3
                aim(side)
                orders[side].busy = 1
                orders[side].setWord(0x12, used + 1)
            }
        }
    }

    /// Carries out both sides' pending orders, then clears them ($6B1B2). Call once
    /// after every `tick`.
    public mutating func processOrders() {
        guard unportedPath == nil else { return }
        for side in 0..<2 {
            let record = orders[side]
            if record.assisted == 1, record.period != 0, Int(tick) % record.period == 0 {
                orders[side].busy = 0
            }
            switch record.action {
            case 0: break
            case 1: reshapeLand(owner: side, x: record.x, y: record.y, raise: true)
            case 2: reshapeLand(owner: side, x: record.x, y: record.y, raise: false)
            case 3: earthquake(owner: side, x: record.x, y: record.y)
            case 4: swamp(owner: side, x: record.x, y: record.y)
            case 5:
                // Move the papal magnet ($6355C); only a side with a leader can.
                if players[side].mana >= Power.magnetCost, players[side].leader != 0, !armageddon {
                    players[side].mana -= Power.magnetCost
                    pendingSound = 0x4D
                    setMagnet(owner: side, cell: min(record.x, 0x3F) + min(record.y, 0x3F) * Self.size)
                }
            case 6: volcano(owner: side, x: record.x, y: record.y)
            case 0xE where record.y == 1:
                players[side].mode = Int16(record.x)
            case 0xE where record.y == 3: startArmageddon(owner: side)
            case 0xE where record.y == 4: flood(owner: side)
            case 0xE where record.y == 5: knight(owner: side)
            default:
                unportedPath = "order \(record.action)/\(record.y)"
                return
            }
        }
        for side in 0..<2 {
            orders[side].action = 0
            orders[side].x = 0
            orders[side].y = 0
        }
    }

    /// Picks a walker's next step when its side is settling ($61CC8): flat land to
    /// live on first, then fights, enemies or friends in sight, else the least
    /// trodden way. Returns a cell offset, 0 to settle here, or `noStep`.
    mutating func chooseSettlingStep(_ index: Int) -> Int {
        let person = people[index]
        let owner = Int(person.owner)
        var minVisits = 9999
        var best = [Int](repeating: 5, count: 5)
        var step = [Int](repeating: 0, count: 5)
        var direction = -1

        for pass in 0..<9 {
            // The first pass looks at the walker's own cell; the rest sweep the eight
            // neighbours from a random start. The sweep wraps through 0, so one
            // neighbour is skipped unless the start is the first.
            if direction == 0, pass == 1 { direction = random.next() & 7 }
            direction += 1
            if direction == 9 { direction = 0 }
            let offset = Self.ringOffsets[direction]
            var cell = Int(person.cell)
            var distance = 0
            while distance != Int(person.byte2), stepCheck(cell, offset) == 0 {
                cell += offset
                var found = false
                if tile[cell] == Tile.flat, distance < best[0] {
                    if direction == 0 {
                        if landScore(owner: owner, cell: cell) != 0 {
                            best[0] = distance
                            step[0] = 0
                            found = true
                        }
                    } else {
                        // Not next to an existing house.
                        let crowded = (9..<17).contains { k in
                            guard stepCheck(cell, Self.ringOffsets[k]) == 0 else { return false }
                            let object = self.object[cell + Self.ringOffsets[k]]
                            return object > 0x20 && object < 0x2D
                        }
                        if !crowded {
                            best[0] = distance
                            step[0] = offset
                            found = true
                        }
                    }
                }
                if !found, direction != 0 {
                    var free = true
                    let there = Int(who[cell])
                    if there != 0, there - 1 != index {
                        let other = people[there - 1]
                        free = false
                        if other.state & Person.State.fighting != 0, distance < best[1] {
                            best[1] = distance
                            step[1] = offset
                        } else if other.owner != person.owner, distance < best[2] {
                            best[2] = distance
                            step[2] = offset
                        } else if other.state & Person.State.walking != 0, distance < best[3] {
                            best[3] = distance
                            step[3] = offset
                        } else {
                            free = true
                        }
                    }
                    if free, offset != Int(person.direction) {
                        let visited = Int(visits[cell])
                        if visited < minVisits || (visited == minVisits && distance < best[4]) {
                            minVisits = visited
                            best[4] = distance
                            step[4] = offset
                        }
                    }
                }
                distance += 1
            }
        }

        let mode = players[owner].mode
        if mode == 3, best[2] != 5 { return step[2] }
        if mode == 2, best[3] != 5 { return step[3] }
        for k in 0..<5 where best[k] != 5 { return step[k] }
        return Self.noStep
    }

    /// Picks a walker's next step when it is heading somewhere ($61FFC): to the
    /// magnet if it is or could become leader, otherwise to the leader.
    mutating func chooseTargetStep(_ index: Int) -> Int {
        let person = people[index]
        let owner = Int(person.owner)
        let cell = Int(person.cell)
        let goal: Int
        if person.long14 != 0 {
            // A knight hunts the nearest enemy, picking a new one when this one is
            // reached, dead, converted or already a ruin.
            var target = people[(Int(person.long14) - Self.peopleAddress) / Person.byteSize]
            if Int(target.cell) == cell || target.life < 1 || target.owner == person.owner || target.state & 0x80 != 0 {
                retarget(index)
                target = people[(Int(people[index].long14) - Self.peopleAddress) / Person.byteSize]
            }
            goal = Int(target.cell)
        } else {
            var magnet = Int(players[owner].magnetCell)
            let leader = Int(players[owner].leader)
            if leader == 0 {
                if magnet == cell {
                    players[owner].leader = Int16(index + 1)
                    if selectedPerson == 0 { selectedPerson = index + 1 }
                }
            } else if leader - 1 != index {
                magnet = Int(people[leader - 1].cell)
            }
            goal = magnet
        }
        let knight = person.long14 != 0
        let dx = ((goal & 0x3F) - (cell & 0x3F)).signum()
        let dy = ((goal >> 6) - (cell >> 6)).signum()

        var direction = Self.directionFromDelta[dy + (dx + 1) * 3 + 1]
        let offset = Self.directionOffsets[direction]
        let check = stepCheck(cell, offset)
        // Knights will not walk into a swamp; during Armageddon rock stops nobody.
        if (check == 0 && (!knight || tile[cell + offset] != Self.swampTile)) || (check == 2 && armageddon) {
            people[index].byte21 = UInt8(truncatingIfNeeded: offset)
            return offset
        }
        // Blocked. A computer-assisted side asks for land to be raised where water or
        // swamp is in the way.
        if orders[owner].assisted == 1 || armageddon, ruleFlags & 4 == 0 || armageddon {
            if check == 3 {
                orders[owner].action = 1
                orders[owner].x = cell & 0x3F
                orders[owner].y = cell >> 6
                orders[owner].busy = 1
            } else if tile.indices.contains(cell + offset), tile[cell + offset] == Self.swampTile,
                ruleFlags & 8 == 0, !armageddon
            {
                orders[owner].action = 1
                orders[owner].x = (cell + offset) & 0x3F
                orders[owner].y = (cell + offset) >> 6
                orders[owner].busy = 1
            }
        }
        // Try the other directions in turn, but not back the way it came.
        let cameFrom = Int(Int8(bitPattern: person.byte21))
        direction -= 1
        for _ in 0..<8 {
            if direction < 0 { direction = 7 }
            if direction > 7 { direction = 0 }
            let candidate = Self.directionOffsets[direction]
            if stepCheck(cell, candidate) == 0, candidate != cameFrom,
                !knight || tile[cell + candidate] != Self.swampTile
            {
                people[index].byte21 = UInt8(
                    truncatingIfNeeded: Self.directionOffsets[Self.oppositeDirection[direction]])
                return candidate
            }
            direction += 1
        }
        people[index].byte21 = UInt8(truncatingIfNeeded: Self.directionOffsets[Self.oppositeDirection[direction]])
        return Self.noStep
    }

    /// Takes a walker's next step, or settles it, or has it meet whoever is already
    /// on its cell ($619F2).
    mutating func moveWalker(_ index: Int, rules: LandRules) {
        let owner = Int(people[index].owner)
        let step: Int
        if players[owner].mode == 0 || people[index].long14 != 0 || armageddon {
            step = chooseTargetStep(index)
        } else {
            step = chooseSettlingStep(index)
        }
        if step == Self.noStep {
            people[index].state |= 0x40
            people[index].word6 = 7
            return
        }
        people[index].state &= ~0x40
        let cell = Int(people[index].cell)
        let previous = cell - Int(people[index].direction)
        if Int(who[previous]) - 1 == index { who[previous] = 0 }
        if orders[owner].assisted == 1, tile[cell] == 0x42, orders[owner].busy == 0, ruleFlags & 0xC == 0 {
            orders[owner].action = 2
            orders[owner].x = cell & 0x3F
            orders[owner].y = cell >> 6
        }

        let other = Int(who[cell]) - 1
        if other != -1, other != index, other < Self.maxPeople, people[other].state & 0x80 == 0 {
            if people[other].state & Person.State.fighting != 0 {
                joinFight(index, at: other)
            } else if people[other].owner != people[index].owner {
                startFight(index, with: other)
                return
            } else {
                merge(index, into: other)
            }
        }

        guard people[index].life > 0 else { return }
        if step == 0, people[index].long14 == 0 {
            if who[cell] == 0 { who[cell] = UInt8(index + 1) }
            people[index].state = Person.State.settled
            people[index].word6 = tick
            animate(index)
            updateHouse(index, removing: false)
        } else {
            visits[cell] &+= 1
            if who[cell] == 0 { who[cell] = UInt8(index + 1) }
            people[index].cell = Int16(cell + step)
            people[index].direction = Int16(step)
        }
    }

    /// One game tick: flips the animation phase and updates everybody ($60B28).
    /// Follow it with `processOrders()`. Flying creatures are not ported.
    public mutating func tick(rules: LandRules) {
        guard unportedPath == nil else { return }
        phase ^= 1
        tick &+= 1

        // The computer thinks first, while last tick's notes on houses still stand.
        for side in 0..<2 {
            if orders[side].busy == 0 { computerStrategy(side) }
            if orders[side].busy == 0, computerUsesPowers { computerPowers(side) }
        }

        var previousHouses = [0, 0]
        var castles = [0, 0]
        var oldest: [UInt16] = [0, 0]
        var best = [0, 0]
        var newest: [UInt16] = [19999, 19999]
        for side in 0..<2 {
            previousHouses[side] = orders[side].castleCount * 3 + orders[side].houseCount
            players[side].houses = 0
            players[side].population = 0
            if phase != 0 { players[side].mana += 1 }
            orders[side].newestHouse = 0
            orders[side].oldestHouse = 0
            orders[side].bestHouse = 0
        }
        while personCount > 0, people[personCount - 1].life == 0 { personCount -= 1 }

        if armageddon {
            let middle = 32 + 32 * Self.size
            players[0].magnetCell = Int16(middle)
            players[1].magnetCell = Int16(middle)
            ankhCell = middle
            skullCell = middle
        }
        // A leader who has become a knight leaves the magnet where he stood.
        for side in 0..<2 {
            let leader = Int(players[side].leader)
            if leader != 0, people[leader - 1].long14 != 0 {
                setMagnet(owner: side, cell: Int(people[leader - 1].cell))
                players[side].leader = 0
            }
        }

        var index = 0
        while index < personCount {
            defer { index += 1 }
            guard people[index].life > 0 else { continue }
            let owner = Int(people[index].owner)
            let other = owner == 0 ? 1 : 0
            players[owner].population += Int32(people[index].life)
            let cell = Int(people[index].cell)

            if people[index].state & Person.State.drowning != 0 {
                if ruleFlags & Rule.waterIsFatal != 0 {
                    removePerson(index)
                    continue
                }
                if (orders[owner].assisted == 1 && ruleFlags & 4 == 0) || armageddon {
                    orders[owner].action = 1
                    orders[owner].x = cell & 0x3F
                    orders[owner].y = cell >> 6
                    orders[owner].busy = 1
                }
                people[index].life &-= Int16(rules.walkCost * 2)
                if tile[cell] == Tile.water {
                    if people[index].life <= 0 { removePerson(index) }
                    continue
                }
                people[index].state &= ~Person.State.drowning
                animate(index)
            } else if tile[cell] == Tile.water {
                if people[index].state & Person.State.settled != 0 { updateHouse(index, removing: true) }
                people[index].state = Person.State.drowning | Person.State.walking
                if people[index].frame >= 8 { people[index].frame = 0 }
            }

            let state = people[index].state
            if state & 4 != 0 {
                if animate(index) {
                    people[index].state &= ~4
                    animate(index)
                }
            } else if state == Person.State.settled {
                let score = landScore(owner: owner, cell: cell)
                if score <= 0 || people[index].long14 != 0 || armageddon {
                    // The land no longer supports a house: back to walking.
                    people[index].state = (state & ~Person.State.settled) | Person.State.walking
                    people[index].frame = 0
                    people[index].direction = 0
                    updateHouse(index, removing: true)
                    continue
                }
                let oldFrame = people[index].frame
                if score >= Self.castleScore {
                    castles[owner] += 1
                    people[index].frame = Self.castleFrame
                } else {
                    people[index].frame = Int16(score * 10 / 0x131 + 0x20)
                    players[owner].houses += 1
                }
                let size = Int(people[index].frame) - 0x20
                if who[cell] == 0 { who[cell] = UInt8(index + 1) }
                let address = address(ofPerson: index)
                if best[owner] < score {
                    best[owner] = score
                    orders[other].bestHouse = address
                }
                let age = tick &- people[index].word6
                if oldest[owner] <= age {
                    oldest[owner] = age
                    orders[other].oldestHouse = address
                }
                if newest[owner] > age {
                    newest[owner] = age
                    orders[owner].newestHouse = address
                }
                if orders[owner].busy == 0 {
                    // Nothing pending for this side: see whether the land round the
                    // house could be improved.
                    if height[cell] == 0 {
                        if people[index].byte20 == 0 || people[index].frame != oldFrame || flatLandSeen {
                            people[index].byte20 = houseAssist(cell: cell, owner: owner)
                        }
                    } else if previousHouses[owner] < 3, tick > 0xFA {
                        _ = houseAssist(cell: cell, owner: owner)
                    }
                }

                if tick & 7 == 0 {
                    var threshold = score
                    if people[index].frame == Self.castleFrame, orders[owner].assisted == 1,
                        people[index].life > 0x131, orders[owner].busy == 0
                    {
                        threshold = 0x131
                        orders[owner].busy = 1
                    }
                    players[owner].mana += Int32(rules.manaGain[size])
                    people[index].byte3 = UInt8(truncatingIfNeeded: rules.strength[size])
                    if Int(people[index].life) > threshold {
                        // Too many for the house: half the threshold stay, the rest
                        // leave as a new walker in the first free slot.
                        splitScratch = 0
                        while splitScratch < Self.maxPeople {
                            let slot = splitScratch
                            if people[slot].life <= 0 {
                                if slot >= personCount { personCount = slot + 1 }
                                people[slot].life = people[index].life &- Int16(threshold >> 1)
                                people[index].life = Int16(threshold >> 1)
                                if Int(players[owner].leader) - 1 == index { players[owner].leader = Int16(slot + 1) }
                                if selectedPerson - 1 == index { selectedPerson = slot + 1 }
                                people[slot].byte2 = people[index].byte2
                                people[slot].cell = people[index].cell
                                people[slot].state = Person.State.walking
                                people[slot].owner = people[index].owner
                                people[slot].direction = 0
                                people[slot].frame = 0
                                people[slot].byte3 = people[index].byte3
                                people[slot].long14 = 0
                                people[slot].word18 = UInt16(bitPattern: people[index].cell)
                                people[slot].byte20 = 0
                                if Int(who[cell]) - 1 == index || who[cell] == 0 { who[cell] = UInt8(slot + 1) }
                                if people[index].byte2 < 4 { people[index].byte2 += 1 }
                                break
                            }
                            splitScratch += 1
                        }
                    }
                    // (With the table full the original releases a flying creature
                    // here; not ported.)
                    people[index].life &+= Int16(rules.lifeGain[size])
                }
                if people[index].frame != oldFrame || flatLandSeen
                    || (people[index].frame == Self.castleFrame && castlePartsSeen < 9)
                {
                    updateHouse(index, removing: false)
                }
            } else if state == Person.State.walking {
                if animate(index) {
                    if tile[cell] == Self.swampTile {
                        removePerson(index)
                        pendingSound = 0x42
                        if ruleFlags & Rule.swampsStay == 0 { tile[cell] = Tile.flat }
                        continue
                    }
                    if orders[other].oldestHouse == 0 { orders[other].oldestHouse = address(ofPerson: index) }
                    if orders[owner].busy == 0 { walkerAssist(cell: cell, owner: owner) }
                    moveWalker(index, rules: rules)
                    let now = people[index]
                    if now.word18 != 0, UInt16(truncatingIfNeeded: Int(now.cell) - Int(now.direction)) != now.word18 {
                        people[index].word18 = 0
                    }
                    people[index].life &-= Int16(rules.walkCost)
                }
                if people[index].life > 0 {
                    // Whoever is standing on the cell being entered stops to greet.
                    let there = Int(who[Int(people[index].cell)]) - 1
                    splitScratch = there
                    if there != index, there != -1, there < Self.maxPeople, people[there].frame == 0,
                        people[there].state & Person.State.drowning == 0
                    {
                        people[there].state |= 0x20
                        people[there].frame = 0x65
                        people[there].word6 = 0
                    }
                }
            } else if state & 0x60 != 0 {
                animate(index)
                people[index].life &-= Int16(rules.walkCost)
                let waited = people[index].word6
                people[index].word6 &+= 1
                if waited > 0xE {
                    people[index].state &= 0x9F
                    animate(index)
                    if people[index].state == Person.State.walking { moveWalker(index, rules: rules) }
                }
            } else if state & Person.State.fighting != 0 {
                // Only the fighter who started it runs the rounds.
                if state == Person.State.fighting {
                    fightRound(index, rules: rules)
                    continue
                }
            } else if state & 0x80 != 0 {
                if who[cell] == 0 { who[cell] = UInt8(index + 1) }
                let left = people[index].word6
                people[index].word6 &-= 1
                if left == 0 { people[index].life = 0 }
            }

            if people[index].life <= 0 { removePerson(index) }
        }

        // A side with nobody left has lost; the original shows its score screen here.
        if defeatedSide == nil {
            defeatedSide = players[0].population == 0 ? 0 : players[1].population == 0 ? 1 : nil
        }
        for side in 0..<2 {
            orders[side].houseCount = Int(players[side].houses)
            orders[side].castleCount = castles[side]
        }
    }
}
