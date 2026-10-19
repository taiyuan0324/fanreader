import Foundation
import Combine
import UIKit

@MainActor
final class LibraryStore: ObservableObject {
    enum SortMode: String, CaseIterable, Identifiable {
        case recent
        case added
        case title

        var id: String { rawValue }

        var name: String {
            switch self {
            case .recent: return "最近阅读"
            case .added: return "导入时间"
            case .title: return "书名"
            }
        }
    }

    @Published private(set) var books: [Book] = []
    @Published var sortMode: SortMode = .recent {
        didSet { UserDefaults.standard.set(sortMode.rawValue, forKey: "library.sort") }
    }

    private let fm = FileManager.default

    private var documents: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    var libraryDirectory: URL {
        documents.appendingPathComponent("Library", isDirectory: true)
    }
    var coverDirectory: URL {
        documents.appendingPathComponent("Covers", isDirectory: true)
    }
    private var indexURL: URL {
        documents.appendingPathComponent("library.json")
    }

    init() {
        try? fm.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: coverDirectory, withIntermediateDirectories: true)
        if let stored = UserDefaults.standard.string(forKey: "library.sort"),
           let mode = SortMode(rawValue: stored) {
            sortMode = mode
        }
        load()
        seedDemoIfNeeded()
    }

    /// CI/截图用:带 -seedDemo 启动参数时塞一本示例书
    private func seedDemoIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-seedDemo"), books.isEmpty else { return }

        let text = """
        第一章 夜航

        船离岸的时候,天还没有全黑。江面上浮着一层薄雾,像谁把整条河的呼吸都收进了口袋里。
        我靠在船舷上,看岸边的灯一盏一盏退后去,最后只剩下一线模糊的黄。

        父亲说,走水路的人要记住两件事:一是天亮之前不要回头看,二是不要在雾里喊人的名字。
        我问他为什么。他没有回答,只是把烟斗在鞋底磕了两下,火星落进水里,连声音都没有。

        第二章 雾中

        后半夜起了风。帆布抖了一下,像有人在外头轻轻拍了拍。
        船工们都睡着了,只有舵楼里还亮着一盏油灯。灯芯很短,光也短,勉强照到我的鞋尖。

        我数着水声,一、二、三……数到第七下的时候,水声忽然停了。
        那种停不是安静,而是所有声音同时被人按住。我听见自己的心跳,一下一下,敲在耳膜上。

        有人在雾里喊我的名字。声音很轻,像隔着很多年。
        我想起父亲的话,把嘴闭紧,手指掐进掌心。指甲陷进去,疼得很真实。

        第三章 天亮

        雾散得很慢。先是桅杆露出来,再是船头,最后才是整条江。
        太阳从右边的山口爬上来,把水面照成一片碎金。船工们醒来,打水,生火,谁也没提夜里的事。

        我回头看,岸已经看不见了。
        父亲站在船尾,把烟斗收进怀里,说:过了这一段,就到地方了。
        我点点头,没有问他,这里究竟是哪里。

        第四章 归途

        多年以后我又坐过一次那条船。江还是那条江,雾还是那样薄。
        只是没有人再喊我的名字,也没有人在天亮之前叮嘱我不要回头。

        我把手伸出船舷,水从指缝里漏下去,凉得像一句没说完的话。
        """

        let id = UUID()
        let fileName = "\(id.uuidString).txt"
        let url = libraryDirectory.appendingPathComponent(fileName)
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)

        var book = Book(id: id, title: "夜航船(示例)", author: "FanReader", format: .txt, fileName: fileName)
        book.lastOpenedAt = nil
        books = [book]
        save()
        ImportLog.write("seeded demo book")
    }

    // MARK: - 查询

    var sortedBooks: [Book] {
        books.sorted { lhs, rhs in
            switch sortMode {
            case .recent:
                let l = lhs.lastOpenedAt ?? lhs.addedAt
                let r = rhs.lastOpenedAt ?? rhs.addedAt
                return l > r
            case .added:
                return lhs.addedAt > rhs.addedAt
            case .title:
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    func search(_ keyword: String) -> [Book] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sortedBooks }
        return sortedBooks.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.author.localizedCaseInsensitiveContains(trimmed)
        }
    }

    func fileURL(for book: Book) -> URL {
        libraryDirectory.appendingPathComponent(book.fileName)
    }

    func coverURL(for book: Book) -> URL? {
        guard let name = book.coverFileName else { return nil }
        let url = coverDirectory.appendingPathComponent(name)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 导入

    /// 导入文件。EPUB 元数据解析放到后台,避免大文件卡住界面。
    @discardableResult
    func importFile(at url: URL) async throws -> Book {
        let id = UUID()
        let fallbackTitle = url.deletingPathExtension().lastPathComponent

        // 安全作用域必须在本线程持有:文件选择器返回的 URL 一旦离开回调作用域就可能失效,
        // 所以先把字节复制进沙盒,再去做耗时的元数据解析。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        ImportLog.write("import start: \(url.lastPathComponent) (ext=\(url.pathExtension.isEmpty ? "-" : url.pathExtension))")
        let format = detectFormat(url: url)
        let ext = url.pathExtension.isEmpty ? format.rawValue : url.pathExtension
        let fileName = "\(id.uuidString).\(ext)"
        let destination = libraryDirectory.appendingPathComponent(fileName)

        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: url, to: destination)
        } catch {
            ImportLog.write("import copy failed: \(url.lastPathComponent) — \(error.localizedDescription)")
            throw ImportError.copyFailed(name: url.lastPathComponent,
                                         reason: error.localizedDescription)
        }

        var metadata = EPUBParser.Metadata()
        if format == .epub {
            metadata = await Task.detached(priority: .userInitiated) {
                EPUBParser.metadata(url: destination)
            }.value
        }

        var book = Book(id: id,
                        title: metadata.title.isEmpty ? fallbackTitle : metadata.title,
                        author: metadata.author,
                        format: format,
                        fileName: fileName)

        if let cover = metadata.cover {
            book.coverFileName = saveCover(cover, for: id)
        }

        books.insert(book, at: 0)
        save()
        ImportLog.write("import ok: \(book.title) [\(book.format.rawValue)]")
        return book
    }

    /// 扫描 Documents 根目录里还没入库的文件(用户从「文件」App 拖进来的)。
    /// 成功后删除原件,避免重复占用空间。
    func scanLocalDocuments() async -> (imported: Int, failed: Int) {
        guard let items = try? fm.contentsOfDirectory(at: documents,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else {
            ImportLog.write("scan: 无法读取 Documents")
            return (0, 0)
        }

        var imported = 0
        var failed = 0

        for item in items {
            let name = item.lastPathComponent
            let skipped = ["Library", "Covers"].contains(name)
                || name.hasSuffix(".json")
                || name.hasSuffix(".log")
                || name.hasPrefix("FanReader-backup")
            guard !skipped,
                  (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }

            do {
                _ = try await importFile(at: item)
                imported += 1
                try? fm.removeItem(at: item)
            } catch {
                ImportLog.write("scan failed \(name): \(error.localizedDescription)")
                failed += 1
            }
        }
        ImportLog.write("scan done: imported=\(imported) failed=\(failed)")
        return (imported, failed)
    }

    /// 扩展名缺失时按魔数判断(从微信/网盘存下来的文件常常没有扩展名)
    private func detectFormat(url: URL) -> BookFormat {
        if !url.pathExtension.isEmpty {
            return BookFormat(fileExtension: url.pathExtension)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .txt }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4)) ?? Data()
        let bytes = [UInt8](head)
        if bytes.count >= 4, bytes[0] == 0x50, bytes[1] == 0x4B, bytes[2] == 0x03, bytes[3] == 0x04 {
            return .epub            // PK.. = zip 容器
        }
        if bytes.count >= 4, bytes[0] == 0x25, bytes[1] == 0x50, bytes[2] == 0x44, bytes[3] == 0x46 {
            return .pdf             // %PDF
        }
        return .txt
    }

    private func saveCover(_ data: Data, for id: UUID) -> String? {
        let name = "\(id.uuidString).img"
        let url = coverDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    // MARK: - 更新

    func update(_ book: Book) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index] = book
        save()
    }

    func toggleFavorite(_ book: Book) {
        var updated = book
        updated.isFavorite.toggle()
        update(updated)
    }

    func delete(_ book: Book) {
        try? fm.removeItem(at: fileURL(for: book))
        if let coverName = book.coverFileName {
            try? fm.removeItem(at: coverDirectory.appendingPathComponent(coverName))
        }
        books.removeAll { $0.id == book.id }
        save()
    }

    /// 重命名(仅改标题)
    func rename(_ book: Book, to title: String) {
        var updated = book
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        update(updated)
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Book].self, from: data) else {
            books = []
            return
        }
        books = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(books) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// 恢复备份后重新读取
    func reload() {
        load()
    }

}


enum ImportError: LocalizedError {
    case copyFailed(name: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .copyFailed(let name, let reason):
            return "无法复制 \(name):\(reason)"
        }
    }
}
