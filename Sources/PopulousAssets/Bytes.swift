/// Big-endian accessors; everything on the Amiga disk is 68000 byte order.
extension Array where Element == UInt8 {
    func be16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func be32(_ offset: Int) -> UInt32 {
        UInt32(be16(offset)) << 16 | UInt32(be16(offset + 2))
    }
}

public enum AssetError: Error, CustomStringConvertible {
    case notAnAmigaDisk(String)
    case corruptDisk(String)
    case fileNotFound(String)
    case unexpectedFormat(file: String, reason: String)

    public var description: String {
        switch self {
        case .notAnAmigaDisk(let why): "Not an AmigaDOS disk image: \(why)"
        case .corruptDisk(let why): "Corrupt disk image: \(why)"
        case .fileNotFound(let name): "File not found on disk: \(name)"
        case .unexpectedFormat(let file, let reason): "\(file): \(reason)"
        }
    }
}
