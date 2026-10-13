import Foundation
import Testing

@testable import PopulousCore

/// A state dump written by re/scripts/EmulateWorld.java.
struct OracleDump {
    var altitude: [UInt8], tile: [UInt8], height: [UInt8], object: [UInt8], visits: [UInt8], who: [UInt8]
    var seed: UInt16
    var people: [UInt8], players: [UInt8]
    var count: Int
    var orders: [UInt8]
    var selected: Int, tick: Int, phase: Int

    init?(world: Int, ticks: Int, label: String = "") {
        let name = "world\(world)" + label + (ticks > 0 ? "-t\(ticks)" : "") + ".bin"
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("re/work/oracle/\(name)")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)
        var offset = 0
        func take(_ n: Int) -> [UInt8] {
            defer { offset += n }
            return Array(bytes[offset..<offset + n])
        }
        func word() -> Int {
            let b = take(2)
            return Int(b[0]) << 8 | Int(b[1])
        }
        altitude = take(65 * 65 * 2)
        tile = take(4096)
        height = take(4096)
        object = take(4096)
        visits = take(8192)
        who = take(4096)
        seed = UInt16(word())
        people = take(211 * 22)
        players = take(32)
        count = word()
        orders = take(92)
        selected = word()
        tick = word()
        phase = word()
    }
}

/// Where two byte arrays first differ, for failure messages.
func firstDifference(_ a: [UInt8], _ b: [UInt8], record: Int = 1) -> String? {
    guard a != b else { return nil }
    let i = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count)
    let start = i / record * record
    let end = min(start + record, a.count)
    func hex(_ x: [UInt8]) -> String { x[start..<min(end, x.count)].map { String(format: "%02x", $0) }.joined(separator: " ") }
    return "at \(i) (record \(i / record)): ours \(hex(a)) theirs \(hex(b))"
}

let land0 = LandRules(landWords: [
    1, 0, 1, 1, 2, 2, 3, 3, 3, 4, 4, 5, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 20, 0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 20,
    50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 2000, 100, 1000, 3000,
])

/// Compares the port tick by tick with dumps from the emulated original. The dumps
/// are produced locally (re/analyze.sh) and are not in the repository, so this is
/// skipped without them.
@Suite(.enabled(if: OracleDump(world: 0, ticks: 0) != nil, "needs re/work/oracle dumps"))
struct OracleTests {
    /// What side 0 does right after setup in a labelled reference run, as
    /// (action letter, x, y): r/l raise/lower, q earthquake, v volcano, s swamp,
    /// k knight, f flood, a Armageddon, m/n both sides get 200000/30000 mana,
    /// h side 0's leader gets life 20000, w run the game to tick x first.
    static let scripts: [String: [(Character, Int, Int)]] = [
        "": [],
        "a": [
            ("r", 10, 3), ("r", 10, 3), ("r", 11, 4), ("l", 7, 4), ("l", 6, 4), ("l", 6, 4), ("r", 40, 40),
            ("r", 40, 40), ("r", 41, 40), ("l", 0, 0), ("r", 64, 64), ("l", 12, 5), ("r", 9, 2), ("r", 9, 2), ("r", 9, 2),
        ],
        "q": [("m", 0, 0), ("q", 6, 1), ("q", 6, 1), ("s", 8, 4), ("v", 20, 20), ("q", 3, 0)],
        "k": [("m", 0, 0), ("k", 0, 0)],
        "f": [("m", 0, 0), ("f", 0, 0)],
        "g": [("m", 0, 0), ("a", 0, 0)],
        "x": [("w", 1000, 0), ("m", 0, 0), ("k", 0, 0)],
        "y": [("w", 1000, 0), ("m", 0, 0), ("a", 0, 0)],
        "z": [("w", 1000, 0), ("m", 0, 0), ("h", 0, 0), ("k", 0, 0)],
        "p": [("m", 0, 0)],
        "n": [("n", 0, 0)],
    ]

    /// World number, seed and script label; all use level record 0 (grass, 3 people
    /// a side, rule flags 3). The dumps were made with the flyer release ($64E46)
    /// skipped; the computer side in this record has no divine powers.
    @Test(arguments: [
        (0, UInt16(0x6302), ""), (5, 0x6307, ""), (7, 0x6309, ""),
        (825, 32399, "p"), (825, 32399, "n"), (5, 0x6307, "x"), (5, 0x6307, "y"), (5, 0x6307, "z"),
        (0, 0x6302, "a"), (0, 0x6302, "q"), (0, 0x6302, "k"), (0, 0x6302, "f"), (0, 0x6302, "g"),
    ])
    func ticksMatchOriginal(_ number: Int, _ seed: UInt16, _ label: String) throws {
        // World 825 uses record 33: rule flags 16 and a computer with every power.
        guard let start = OracleDump(world: number, ticks: 0, label: number == 825 ? label : "") else { return }
        var world = World.conquest(seed: seed, startingPeople: (3, 3))
        world.ruleFlags = number == 825 ? 16 : 3
        world.orders = [Orders(bytes: Array(start.orders[..<46])), Orders(bytes: Array(start.orders[46...]))]
        var done = 0
        for (action, x, y) in Self.scripts[label]! {
            switch action {
            case "w":
                while done < x {
                    world.tick(rules: land0)
                    world.processOrders()
                    done += 1
                }
            case "r": world.reshapeLand(owner: 0, x: x, y: y, raise: true)
            case "l": world.reshapeLand(owner: 0, x: x, y: y, raise: false)
            case "q": world.earthquake(owner: 0, x: x, y: y)
            case "v": world.volcano(owner: 0, x: x, y: y)
            case "s": world.swamp(owner: 0, x: x, y: y)
            case "k": world.knight(owner: 0)
            case "f": world.flood(owner: 0)
            case "a": world.startArmageddon(owner: 0)
            case "h":
                let leader = Int(world.players[0].leader) - 1
                if leader >= 0 { world.people[leader].life = 20000 }
            case "n":
                world.players[0].mana = 30_000
                world.players[1].mana = 30_000
            default:
                world.players[0].mana = 200_000
                world.players[1].mana = 200_000
            }
        }
        if !label.isEmpty {
            guard let edited = OracleDump(world: number, ticks: done, label: label) else { return }
            #expect(firstDifference(world.altitude.flatMap { [UInt8(truncatingIfNeeded: $0 >> 8), UInt8(truncatingIfNeeded: $0)] }, edited.altitude, record: 2) == nil, "altitude \(label)")
            #expect(firstDifference(world.tile, edited.tile) == nil, "tile \(label)")
            #expect(firstDifference(world.height, edited.height) == nil, "height \(label)")
            #expect(firstDifference(world.object, edited.object) == nil, "object \(label)")
            #expect(firstDifference(world.people.flatMap(\.bytes), edited.people, record: 22) == nil, "people \(label)")
            #expect(firstDifference(world.players.flatMap(\.bytes), edited.players, record: 16) == nil, "players \(label)")
            #expect(world.random.seed == edited.seed, "seed \(label)")
        }

        var compared = 0
        for ticks in done + 1...3000 {
            world.tick(rules: land0)
            world.processOrders()
            if let path = world.unportedPath {
                print("world \(number)\(label): reached unported path '\(path)' at tick \(ticks) after \(compared) matching dumps")
                break
            }
            guard let dump = OracleDump(world: number, ticks: ticks, label: label) else { continue }
            var problems: [String] = []
            func check(_ name: String, _ ours: [UInt8], _ theirs: [UInt8], record: Int = 1) {
                if let difference = firstDifference(ours, theirs, record: record) {
                    problems.append("\(name) \(difference)")
                }
            }
            check("people", world.people.flatMap(\.bytes), dump.people, record: 22)
            check("players", world.players.flatMap(\.bytes), dump.players, record: 16)
            check("orders", world.orders.flatMap(\.bytes), dump.orders, record: 46)
            check("altitude", world.altitude.flatMap { [UInt8(truncatingIfNeeded: $0 >> 8), UInt8(truncatingIfNeeded: $0)] }, dump.altitude, record: 2)
            check("height", world.height, dump.height)
            check("tile", world.tile, dump.tile)
            check("object", world.object, dump.object)
            check("who", world.who, dump.who)
            check("visits", world.visits.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }, dump.visits, record: 2)
            if world.personCount != dump.count { problems.append("count \(world.personCount) vs \(dump.count)") }
            if world.random.seed != dump.seed { problems.append("seed \(world.random.seed) vs \(dump.seed)") }
            if world.selectedPerson != dump.selected { problems.append("selected \(world.selectedPerson) vs \(dump.selected)") }
            #expect(problems.isEmpty, "world \(number)\(label) after \(ticks) ticks: \(problems.joined(separator: "; "))")
            if !problems.isEmpty { return }
            compared += 1
            if ticks % 1000 == 0 || (number == 825 && ticks == 600) { print("fingerprint world \(number)\(label) tick \(ticks): 0x\(String(world.fingerprint, radix: 16))") }
        }
        print("world \(number)\(label): \(compared) dumps compared, \(world.personCount) people")
    }
}
