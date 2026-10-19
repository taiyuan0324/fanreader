import Foundation

enum BookFormat: String, Codable {
    case txt
    case epub
    case pdf

    init(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "epub": self = .epub
        case "pdf": self = .pdf
        default: self = .txt
        }
    }
}

struct Book: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var author: String
    var format: BookFormat
    /// 库内文件名,相对于 Library 目录
    var fileName: String
    /// 封面文件名,相对于 Covers 目录
    var coverFileName: String?
    var addedAt: Date
    var lastOpenedAt: Date?
    var progress: Double
    var chapterIndex: Int
    var pageIndex: Int
    var isFavorite: Bool
    var chapterTitle: String

    init(id: UUID = UUID(),
         title: String,
         author: String = "",
         format: BookFormat,
         fileName: String) {
        self.id = id
        self.title = title
        self.author = author
        self.format = format
        self.fileName = fileName
        self.coverFileName = nil
        self.addedAt = Date()
        self.lastOpenedAt = nil
        self.progress = 0
        self.chapterIndex = 0
        self.pageIndex = 0
        self.isFavorite = false
        self.chapterTitle = ""
    }

    var subtitle: String {
        author.isEmpty ? format.rawValue.uppercased() : author
    }
}

struct Chapter: Identifiable {
    let id: Int
    let title: String
    let text: String
}

struct BookDocument {
    var title: String
    var author: String
    var chapters: [Chapter]
}

struct SearchHit: Identifiable {
    let id = UUID()
    let chapterIndex: Int
    let chapterTitle: String
    let snippet: String
}

struct Bookmark: Identifiable, Codable, Hashable {
    let id: UUID
    let bookID: UUID
    var chapterIndex: Int
    var pageIndex: Int
    var chapterTitle: String
    var snippet: String
    var createdAt: Date

    init(bookID: UUID,
         chapterIndex: Int,
         pageIndex: Int,
         chapterTitle: String,
         snippet: String) {
        self.id = UUID()
        self.bookID = bookID
        self.chapterIndex = chapterIndex
        self.pageIndex = pageIndex
        self.chapterTitle = chapterTitle
        self.snippet = snippet
        self.createdAt = Date()
    }
}
