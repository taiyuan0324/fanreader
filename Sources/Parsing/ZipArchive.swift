import Foundation
import Compression

/// 最小 ZIP 读取器:只做解包(存储在 + deflate),够 EPUB 用。
/// 依赖系统 Compression 框架,不引入第三方库。
struct ZipEntry {
    let path: String
    let method: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
}

final class ZipArchive {
    private let bytes: [UInt8]
    private(set) var entries: [String: ZipEntry] = [:]

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        bytes = [UInt8](data)
        guard indexCentralDirectory() else { return nil }
    }

    func data(for path: String) -> Data? {
        guard let entry = entries[path] else { return nil }
        let base = entry.localHeaderOffset
        guard base + 30 <= bytes.count, u32(base) == 0x0403_4b50 else { return nil }

        let nameLength = Int(u16(base + 26))
        let extraLength = Int(u16(base + 28))
        let start = base + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= bytes.count else { return nil }

        let payload = Array(bytes[start ..< (start + entry.compressedSize)])
        switch entry.method {
        case 0:
            return Data(payload)
        case 8:
            return ZipArchive.inflate(payload, expected: entry.uncompressedSize)
        default:
            return nil
        }
    }

    // MARK: - 中央目录

    private func indexCentralDirectory() -> Bool {
        let count = bytes.count
        guard count > 22 else { return false }

        var eocd = -1
        var cursor = count - 22
        let lowerBound = max(0, count - 22 - 65_535)
        while cursor >= lowerBound {
            if u32(cursor) == 0x0605_4b50 {
                eocd = cursor
                break
            }
            cursor -= 1
        }
        guard eocd >= 0 else { return false }

        let entryCount = Int(u16(eocd + 10))
        var offset = Int(u32(eocd + 16))

        for _ in 0 ..< entryCount {
            guard offset + 46 <= count, u32(offset) == 0x0201_4b50 else { break }
            let method = u16(offset + 10)
            let compressed = Int(u32(offset + 20))
            let uncompressed = Int(u32(offset + 24))
            let nameLength = Int(u16(offset + 28))
            let extraLength = Int(u16(offset + 30))
            let commentLength = Int(u16(offset + 32))
            let localOffset = Int(u32(offset + 42))

            guard offset + 46 + nameLength <= count else { break }
            let name = String(decoding: bytes[(offset + 46) ..< (offset + 46 + nameLength)], as: UTF8.self)
            entries[name] = ZipEntry(path: name,
                                     method: method,
                                     compressedSize: compressed,
                                     uncompressedSize: uncompressed,
                                     localHeaderOffset: localOffset)
            offset += 46 + nameLength + extraLength + commentLength
        }
        return !entries.isEmpty
    }

    // MARK: - 字节读取

    private func u16(_ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func u32(_ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    // MARK: - deflate

    private static func inflate(_ source: [UInt8], expected: Int) -> Data? {
        var capacity = max(expected, 1024)
        let upperBound = 64 * 1024 * 1024

        while capacity <= upperBound {
            var output = [UInt8](repeating: 0, count: capacity)
            let written = source.withUnsafeBufferPointer { src in
                output.withUnsafeMutableBufferPointer { dst -> Int in
                    guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else { return 0 }
                    return compression_decode_buffer(dstBase, dst.count,
                                                     srcBase, src.count,
                                                     nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 {
                return Data(output[0 ..< written])
            }
            capacity *= 2
        }
        return nil
    }
}
