/// A saved game in the original's file layout ($6A9DE / $6ADD0), so games move
/// between this port and the Amiga original.
public struct SaveGame: Sendable {
    public var world: World
    /// What the mouse does in the close-up: 1 inspect, 2 reshape land.
    public var cursorMode = 2
    /// The seed the world was generated from.
    public var worldSeed: UInt16 = 0
    /// Land set, 0...3.
    public var terrain = 0
    /// The world's 10-byte level record and its number (-1 for a custom game).
    public var levelRecord = [UInt8](repeating: 0, count: 10)
    public var worldNumber = 0
    /// The world reached in the conquest.
    public var conquestWorld = 0

    public init(world: World) {
        self.world = world
    }

    static let magic: [UInt8] = [0xFF, 0xFF, 0xB6, 0x15]
    static let byteSize = 4 + 8450 + 4 * 4096 + 32 + 211 * 22 + 2 * 46 + 2 * 7 + 10 + 2 + 2 + 4 + 2 + 2 + 4 + 2

    public enum LoadError: Error {
        case notASaveGame
    }

    /// The file contents.
    public var bytes: [UInt8] {
        func word(_ value: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }
        func long(_ value: Int) -> [UInt8] { word(value >> 16) + word(value) }
        let altitude = world.altitude.flatMap { word(Int($0)) }
        let layers = world.height + world.tile + world.object + world.who

        var out = Self.magic + altitude + layers
        out += world.players.flatMap(\.bytes)
        out += world.people.flatMap(\.bytes)
        out += world.orders.flatMap(\.bytes)
        out += word(cursorMode) + word(Int(world.random.seed)) + word(Int(worldSeed))
        out += word(0)  // the side the human plays
        out += word(terrain) + word(world.armageddon ? 1 : 0) + word(Int(world.tick))
        out += levelRecord + word(worldNumber)
        out += word(0)  // paint mode
        out += word(Int(world.kills[0])) + word(Int(world.kills[1]))
        out += word(world.ruleFlags) + word(conquestWorld) + long(world.score)

        // A 16-bit sum over the land and both populations closes the file. The
        // original writes it but never checks it.
        var sum = 0
        let summed = altitude + layers
        for i in stride(from: 0, to: summed.count - 1, by: 2) { sum += Int(summed[i]) << 8 | Int(summed[i + 1]) }
        sum += Int(world.players[0].population) + Int(world.players[1].population)
        return out + word(sum)
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count >= Self.byteSize, Array(bytes[..<4]) == Self.magic else { throw LoadError.notASaveGame }
        var offset = 4
        func take(_ count: Int) -> [UInt8] {
            defer { offset += count }
            return Array(bytes[offset..<offset + count])
        }
        func word() -> Int {
            let b = take(2)
            return Int(b[0]) << 8 | Int(b[1])
        }

        var world = World(random: GameRandom(seed: 0))
        let altitude = take(8450)
        world.altitude = (0..<4225).map { Int16(bitPattern: UInt16(altitude[$0 * 2]) << 8 | UInt16(altitude[$0 * 2 + 1])) }
        world.height = take(4096)
        world.tile = take(4096)
        world.object = take(4096)
        world.who = take(4096)
        world.players = (0..<2).map { _ in Player(bytes: take(16)) }
        world.people = (0..<World.peopleSlots).map { _ in Person(bytes: take(Person.byteSize)) }
        world.orders = (0..<2).map { _ in Orders(bytes: take(Orders.byteSize)) }
        cursorMode = word()
        world.random.seed = UInt16(word())
        worldSeed = UInt16(word())
        _ = word()
        terrain = word() & 3
        world.armageddon = word() != 0
        world.tick = UInt16(word())
        levelRecord = take(10)
        worldNumber = Int(Int16(bitPattern: UInt16(word())))
        _ = word()
        world.kills = [UInt16(word()), UInt16(word())]
        world.ruleFlags = word()
        conquestWorld = word()
        world.score = word() << 16 | word()

        // As the original does after loading: magnets drawn where the players have
        // them, the people count found again, pending orders dropped, and knights
        // pointed at fresh targets.
        world.ankhCell = Int(world.players[0].magnetCell)
        world.skullCell = Int(world.players[1].magnetCell)
        world.personCount = (world.people[..<World.maxPeople].lastIndex { $0.life != 0 } ?? -1) + 1
        for side in 0..<2 {
            world.orders[side].action = 0
            world.orders[side].x = 0
            world.orders[side].y = 0
        }
        for index in 0..<world.personCount where world.people[index].long14 != 0 { world.retarget(index) }
        self.world = world
    }
}
