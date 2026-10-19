import Foundation

/// 最小 ZIP 写入器(仅 store 方式,不压缩),用于导出备份。零第三方依赖。
struct ZipWriter {
    private struct Entry {
        let path: String
        let data: Data
    }

    private var entries: [Entry] = []

    mutating func addFile(path: String, data: Data) {
        entries.append(Entry(path: path, data: data))
    }

    mutating func addDirectoryContents(at directory: URL, prefix: String) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return }
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: fileURL) else { continue }
            let relative = fileURL.path.replacingOccurrences(of: directory.path + "/", with: "")
            addFile(path: prefix + relative, data: data)
        }
    }

    func build() -> Data {
        var output = Data()
        var centralDirectory = Data()

        for entry in entries {
            let nameBytes = Array(entry.path.utf8)
            let crc = CRC32.checksum(entry.data)
            let offset = UInt32(output.count)

            var local = Data()
            local.append(uint32: 0x0403_4b50)
            local.append(uint16: 20)              // version needed
            local.append(uint16: 0x0800)          // UTF-8 flag
            local.append(uint16: 0)               // stored
            local.append(uint16: 0)               // time
            local.append(uint16: 0x21)            // date (1980-01-01)
            local.append(uint32: crc)
            local.append(uint32: UInt32(entry.data.count))
            local.append(uint32: UInt32(entry.data.count))
            local.append(uint16: UInt16(nameBytes.count))
            local.append(uint16: 0)
            local.append(contentsOf: nameBytes)
            local.append(entry.data)
            output.append(local)

            centralDirectory.append(uint32: 0x0201_4b50)
            centralDirectory.append(uint16: 20)   // version made by
            centralDirectory.append(uint16: 20)   // version needed
            centralDirectory.append(uint16: 0x0800)
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint16: 0x21)
            centralDirectory.append(uint32: crc)
            centralDirectory.append(uint32: UInt32(entry.data.count))
            centralDirectory.append(uint32: UInt32(entry.data.count))
            centralDirectory.append(uint16: UInt16(nameBytes.count))
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint32: 0)
            centralDirectory.append(uint32: offset)
            centralDirectory.append(contentsOf: nameBytes)
        }

        let centralOffset = UInt32(output.count)
        output.append(centralDirectory)

        output.append(uint32: 0x0605_4b50)
        output.append(uint16: 0)
        output.append(uint16: 0)
        output.append(uint16: UInt16(entries.count))
        output.append(uint16: UInt16(entries.count))
        output.append(uint32: UInt32(centralDirectory.count))
        output.append(uint32: centralOffset)
        output.append(uint16: 0)

        return output
    }
}

enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func append(uint32 value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
