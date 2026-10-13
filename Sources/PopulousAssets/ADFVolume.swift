/// Read-only AmigaDOS floppy image (OFS or FFS, 512-byte blocks).
public struct ADFVolume: Sendable {
    public struct Entry: Sendable {
        /// Path from the volume root, `/`-separated, original case.
        public let path: String
        public let isDirectory: Bool
        public let size: Int
        let headerBlock: Int
    }

    public let name: String
    public let isFFS: Bool
    /// Every file and directory on the volume, directories before their children.
    public let entries: [Entry]

    private let data: [UInt8]
    private static let blockSize = 512
    private static let hashTableSize = 72

    public init(data: [UInt8]) throws {
        let bs = Self.blockSize
        guard data.count >= bs * 4, data.count % bs == 0 else {
            throw AssetError.notAnAmigaDisk("size \(data.count) is not a whole number of blocks")
        }
        guard data[0] == 0x44, data[1] == 0x4F, data[2] == 0x53 else {
            throw AssetError.notAnAmigaDisk("missing DOS signature")
        }
        self.data = data
        isFFS = data[3] & 1 != 0

        let blockCount = data.count / bs
        let root = blockCount / 2
        let rootBase = root * bs
        guard data.be32(rootBase) == 2, data.be32(rootBase + bs - 4) == 1 else {
            throw AssetError.corruptDisk("root block not found at block \(root)")
        }
        name = Self.name(in: data, block: root)

        var found: [Entry] = []
        var visited: Set<Int> = [root]
        try Self.walk(data, directory: root, prefix: "", visited: &visited, into: &found)
        entries = found
    }

    /// Contents of a file; the path is matched case-insensitively, as AmigaDOS does.
    public func contents(of path: String) throws -> [UInt8] {
        let wanted = path.lowercased()
        guard let entry = entries.first(where: { !$0.isDirectory && $0.path.lowercased() == wanted }) else {
            throw AssetError.fileNotFound(path)
        }
        return try contents(of: entry)
    }

    public func contents(of entry: Entry) throws -> [UInt8] {
        let bs = Self.blockSize
        let blockCount = data.count / bs
        var out: [UInt8] = []
        out.reserveCapacity(entry.size)
        var header = entry.headerBlock
        var visited: Set<Int> = []
        while header != 0 {
            guard header < blockCount, visited.insert(header).inserted else {
                throw AssetError.corruptDisk("bad block chain in \(entry.path)")
            }
            let base = header * bs
            let count = Int(data.be32(base + 8))
            guard count <= Self.hashTableSize else {
                throw AssetError.corruptDisk("bad block count in \(entry.path)")
            }
            // Data block pointers are stored backwards from the end of the table.
            for i in 0..<count {
                let block = Int(data.be32(base + bs - 204 - i * 4))
                guard block > 0, block < blockCount else {
                    throw AssetError.corruptDisk("bad data block in \(entry.path)")
                }
                let start = block * bs
                if isFFS {
                    out.append(contentsOf: data[start..<start + bs])
                } else {
                    let used = min(Int(data.be32(start + 12)), bs - 24)
                    out.append(contentsOf: data[start + 24..<start + 24 + used])
                }
            }
            header = Int(data.be32(base + bs - 8))
        }
        guard out.count >= entry.size else {
            throw AssetError.corruptDisk("\(entry.path) is shorter than its header says")
        }
        out.removeLast(out.count - entry.size)
        return out
    }

    private static func name(in data: [UInt8], block: Int) -> String {
        let base = block * blockSize + blockSize - 80
        let length = min(Int(data[base]), 30)
        return String(decoding: data[base + 1..<base + 1 + length].map { UInt16($0) }, as: UTF16.self)
    }

    private static func walk(
        _ data: [UInt8], directory: Int, prefix: String,
        visited: inout Set<Int>, into found: inout [Entry]
    ) throws {
        let bs = blockSize
        let blockCount = data.count / bs
        for slot in 0..<hashTableSize {
            var block = Int(data.be32(directory * bs + 24 + slot * 4))
            while block != 0 {
                guard block < blockCount, visited.insert(block).inserted else {
                    throw AssetError.corruptDisk("bad directory chain at block \(block)")
                }
                let base = block * bs
                let secondaryType = Int32(bitPattern: data.be32(base + bs - 4))
                let path = prefix + name(in: data, block: block)
                switch secondaryType {
                case 2:
                    found.append(Entry(path: path, isDirectory: true, size: 0, headerBlock: block))
                    try walk(data, directory: block, prefix: path + "/", visited: &visited, into: &found)
                case -3:
                    let size = Int(data.be32(base + bs - 188))
                    found.append(Entry(path: path, isDirectory: false, size: size, headerBlock: block))
                default:
                    break  // links etc.; the game disk has none
                }
                block = Int(data.be32(base + bs - 16))
            }
        }
    }
}
