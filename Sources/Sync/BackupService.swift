import Foundation

/// 本地备份/恢复:把书库、封面、书签打包成一个 zip,可经「文件」App 导出到 iCloud 或电脑。
@MainActor
final class BackupService {
    static let shared = BackupService()

    private let fm = FileManager.default

    private var documents: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var libraryDirectory: URL { documents.appendingPathComponent("Library", isDirectory: true) }
    private var coverDirectory: URL { documents.appendingPathComponent("Covers", isDirectory: true) }
    private var indexURL: URL { documents.appendingPathComponent("library.json") }
    private var bookmarkURL: URL { documents.appendingPathComponent("bookmarks.json") }

    private var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }

    func export() throws -> URL {
        var writer = ZipWriter()

        if let index = try? Data(contentsOf: indexURL) {
            writer.addFile(path: "library.json", data: index)
        }
        if let bookmarks = try? Data(contentsOf: bookmarkURL) {
            writer.addFile(path: "bookmarks.json", data: bookmarks)
        }
        writer.addDirectoryContents(at: libraryDirectory, prefix: "Library/")
        writer.addDirectoryContents(at: coverDirectory, prefix: "Covers/")

        let name = "FanReader-backup-\(formatter.string(from: Date())).zip"
        let destination = documents.appendingPathComponent(name)
        try writer.build().write(to: destination, options: .atomic)
        return destination
    }

    /// 用备份文件覆盖当前书库。调用方需在完成后刷新 LibraryStore。
    func restore(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let archive = ZipArchive(url: url) else {
            throw NSError(domain: "FanReader", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "不是有效的备份文件"])
        }

        if let index = archive.data(for: "library.json") {
            try index.write(to: indexURL, options: .atomic)
        }
        if let bookmarks = archive.data(for: "bookmarks.json") {
            try bookmarks.write(to: bookmarkURL, options: .atomic)
        }

        try? fm.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: coverDirectory, withIntermediateDirectories: true)

        for path in archive.entries.keys {
            guard let data = archive.data(for: path) else { continue }
            let destination: URL
            if path.hasPrefix("Library/") {
                destination = libraryDirectory.appendingPathComponent(String(path.dropFirst("Library/".count)))
            } else if path.hasPrefix("Covers/") {
                destination = coverDirectory.appendingPathComponent(String(path.dropFirst("Covers/".count)))
            } else {
                continue
            }
            try? data.write(to: destination, options: .atomic)
        }
    }
}
