import CZlib
import Foundation

/// Fast path for ordinary single-disk ZIP packages. Other ZIP variants use the
/// existing system reader, so unusual archives keep the same compatibility.
struct PowerPointZipIndex {
    private struct Entry {
        let flags: Int
        let method: Int
        let checksum: UInt32
        let packedSize: Int
        let size: Int
        let offset: Int
    }

    private let archive: Data
    private let files: [String: Entry]
    private let directory: Int

    init?(url: URL) {
        guard let archive = try? Data(contentsOf: url, options: .mappedIfSafe), archive.count >= 22 else { return nil }
        let parsed = archive.withUnsafeBytes { bytes -> (Int, [String: Entry])? in
            func read(_ offset: Int, _ count: Int) -> Int {
                (0..<count).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
            }
            let minimum = max(0, bytes.count - 65_557)
            guard let end = stride(from: bytes.count - 22, through: minimum, by: -1).first(where: {
                read($0, 4) == 0x06054b50 && read($0 + 20, 2) == bytes.count - $0 - 22
            }), read(end + 4, 4) == 0 else { return nil }
            let count = read(end + 10, 2)
            let directory = read(end + 16, 4)
            let size = read(end + 12, 4)
            guard count < 65_535, read(end + 8, 2) == count, directory <= end, size <= end - directory else { return nil }
            let limit = directory + size
            var cursor = directory
            var files: [String: Entry] = [:]
            for _ in 0..<count {
                if Task.isCancelled { return nil }
                guard cursor <= limit - 46, read(cursor, 4) == 0x02014b50, read(cursor + 34, 2) == 0 else { return nil }
                let length = read(cursor + 28, 2)
                let next = cursor + 46 + length + read(cursor + 30, 2) + read(cursor + 32, 2)
                guard next <= limit, length > 0,
                      let name = String(bytes: bytes[(cursor + 46)..<(cursor + 46 + length)], encoding: .utf8),
                      files[name] == nil else { return nil }
                let entry = Entry(flags: read(cursor + 8, 2), method: read(cursor + 10, 2),
                                  checksum: UInt32(read(cursor + 16, 4)), packedSize: read(cursor + 20, 4),
                                  size: read(cursor + 24, 4), offset: read(cursor + 42, 4))
                guard entry.packedSize < 0xffffffff, entry.size < 0xffffffff, entry.offset < directory else { return nil }
                files[name] = entry
                cursor = next
            }
            guard cursor == limit else { return nil }
            return (directory, files)
        }
        guard let (directory, files) = parsed else { return nil }
        self.archive = archive
        self.directory = directory
        self.files = files
    }

    func part(_ path: String, maximum: Int, optional: Bool) throws -> Data? {
        try Task.checkCancellation()
        guard let entry = files[path] else {
            if optional { return nil }
            throw PowerPointReadError.missingPart(path)
        }
        if entry.flags & 1 != 0 { throw PowerPointReadError.protected }
        guard entry.size <= maximum else { throw PowerPointReadError.limit(path) }
        let result = archive.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Data? in
            func read(_ offset: Int, _ count: Int) -> Int {
                (0..<count).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
            }
            let offset = entry.offset
            guard offset <= directory - 30, read(offset, 4) == 0x04034b50,
                  read(offset + 6, 2) == entry.flags, read(offset + 8, 2) == entry.method else { return nil }
            let nameLength = read(offset + 26, 2)
            let start = offset + 30 + nameLength + read(offset + 28, 2)
            guard start <= directory, entry.packedSize <= directory - start,
                  String(bytes: bytes[(offset + 30)..<(offset + 30 + nameLength)], encoding: .utf8) == path else { return nil }
            let packed = bytes.bindMemory(to: UInt8.self).baseAddress!.advanced(by: start)
            let data: Data
            switch entry.method {
            case 0:
                guard entry.packedSize == entry.size else { return nil }
                data = Data(bytes: packed, count: entry.size)
            case 8:
                guard let inflated = Self.inflate(packed, count: entry.packedSize, size: entry.size) else { return nil }
                data = inflated
            default: return nil
            }
            let checksum = data.withUnsafeBytes { raw in
                crc32(0, raw.bindMemory(to: UInt8.self).baseAddress, UInt32(data.count))
            }
            return checksum == uLong(entry.checksum) ? data : nil
        }
        try Task.checkCancellation()
        guard let result else { throw PowerPointReadError.invalidPart(path) }
        return result
    }

    func supports(_ path: String) -> Bool {
        guard let entry = files[path] else { return true }
        return [0, 8].contains(entry.method)
    }

    private static func inflate(_ input: UnsafePointer<UInt8>, count: Int, size: Int) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data(count: size + 1)
        let status = output.withUnsafeMutableBytes { bytes -> Int32 in
            stream.next_in = UnsafeMutablePointer(mutating: input)
            stream.avail_in = UInt32(count)
            stream.next_out = bytes.bindMemory(to: UInt8.self).baseAddress
            stream.avail_out = UInt32(size + 1)
            return CZlib.inflate(&stream, Z_FINISH)
        }
        guard status == Z_STREAM_END, stream.total_out == size, stream.avail_in == 0 else { return nil }
        output.removeLast()
        return output
    }
}
