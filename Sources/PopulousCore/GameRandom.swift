/// The game's pseudo-random generator (original routine at $6C25E).
/// Everything random in a world flows from one of these, so call order matters.
public struct GameRandom: Sendable, Equatable {
    public var seed: UInt16

    public init(seed: UInt16) {
        self.seed = seed
    }

    /// Advances the generator; the result is in 0...0x7FFF.
    public mutating func next() -> Int {
        seed = (seed &* 9377 &+ 9439) & 0x7FFF
        return Int(seed)
    }
}
