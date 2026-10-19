import Foundation

/// 导入过程日志,写到 Documents/import.log。
/// 可通过「文件」App → 我的 iPhone → 翻页 → import.log 查看,或 App 设置页内查看。
enum ImportLog {
    private static let maxLines = 300

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("import.log")
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        let url = fileURL

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        } else {
            try? line.data(using: .utf8)?.write(to: url, options: .atomic)
        }
        trimIfNeeded()
    }

    static func read() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "(没有日志)"
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func trimIfNeeded() {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return }
        let kept = lines.suffix(maxLines).joined(separator: "\n")
        try? kept.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
