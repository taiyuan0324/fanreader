import Foundation

enum ParseError: LocalizedError {
    case badArchive
    case missingPackage
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case .badArchive: return "压缩包无法解析"
        case .missingPackage: return "EPUB 缺少 OPF 描述文件"
        case .emptyDocument: return "文档内容为空"
        }
    }
}

enum EPUBParser {
    struct Metadata {
        var title: String = ""
        var author: String = ""
        var cover: Data?
    }

    struct Session {
        var archive: ZipArchive
        var package: OPFScanner.Package
        var baseDirectory: String
    }

    // MARK: - 对外接口

    static func document(url: URL, fallbackTitle: String) throws -> BookDocument {
        let session = try openSession(url: url)
        let toc = tableOfContents(session: session)

        var chapters: [Chapter] = []
        var seen = Set<String>()

        for idref in session.package.spine {
            guard let item = session.package.manifest[idref] else { continue }
            let path = resolve(href: item.href, base: session.baseDirectory)
            guard seen.insert(path).inserted else { continue }
            guard let raw = session.archive.data(for: path) else { continue }

            let html = TextDecoding.decode(raw)
            let text = HTMLText.plain(from: html)
            guard text.count > 1 else { continue }

            let title = toc[path]
                ?? HTMLText.heading(from: html)
                ?? "第 \(chapters.count + 1) 节"
            chapters.append(Chapter(id: chapters.count, title: title, text: text))
        }

        guard !chapters.isEmpty else { throw ParseError.emptyDocument }

        let title = session.package.title.isEmpty ? fallbackTitle : session.package.title
        return BookDocument(title: title, author: session.package.author, chapters: chapters)
    }

    static func metadata(url: URL) -> Metadata {
        guard let session = try? openSession(url: url) else { return Metadata() }
        var meta = Metadata()
        meta.title = session.package.title
        meta.author = session.package.author
        meta.cover = coverData(session: session)
        return meta
    }

    // MARK: - 内部

    private static func openSession(url: URL) throws -> Session {
        guard let archive = ZipArchive(url: url) else { throw ParseError.badArchive }

        let containerData = archive.data(for: "META-INF/container.xml") ?? Data()
        let packagePath = OPFScanner.rootFilePath(from: containerData) ?? "OEBPS/content.opf"

        guard let packageData = archive.data(for: packagePath) else { throw ParseError.missingPackage }
        let package = OPFScanner.parse(packageData)
        let baseDirectory = (packagePath as NSString).deletingLastPathComponent

        return Session(archive: archive, package: package, baseDirectory: baseDirectory)
    }

    private static func tableOfContents(session: Session) -> [String: String] {
        let items = session.package.manifest

        // EPUB3:properties 含 nav 的 XHTML
        if let navItem = items.values.first(where: { $0.isNavigation }) {
            let path = resolve(href: navItem.href, base: session.baseDirectory)
            if let raw = session.archive.data(for: path) {
                let html = TextDecoding.decode(raw)
                let map = EPUBTOC.parseNavigation(html)
                if !map.isEmpty {
                    return rebase(map, relativeTo: path)
                }
            }
        }

        // EPUB2:NCX
        var ncx: OPFScanner.Item?
        if let tocID = session.package.tocID, let item = items[tocID] {
            ncx = item
        } else {
            ncx = items.values.first { $0.mediaType.contains("dtbncx") }
        }
        if let ncx {
            let path = resolve(href: ncx.href, base: session.baseDirectory)
            if let raw = session.archive.data(for: path) {
                let xml = TextDecoding.decode(raw)
                let map = EPUBTOC.parseNCX(xml)
                if !map.isEmpty {
                    return rebase(map, relativeTo: path)
                }
            }
        }
        return [:]
    }

    /// TOC 里的 href 是相对 nav/ncx 文件所在目录,统一换算到压缩包根路径
    private static func rebase(_ map: [String: String],
                               relativeTo tocPath: String) -> [String: String] {
        let tocDirectory = (tocPath as NSString).deletingLastPathComponent
        var result: [String: String] = [:]
        for (href, title) in map {
            result[resolve(href: href, base: tocDirectory)] = title
        }
        return result
    }

    private static func coverData(session: Session) -> Data? {
        let items = session.package.manifest

        if let coverID = session.package.coverID,
           let item = items[coverID] {
            let path = resolve(href: item.href, base: session.baseDirectory)
            if let data = session.archive.data(for: path) { return data }
        }

        if let item = items.values.first(where: { $0.isCoverImage }) {
            let path = resolve(href: item.href, base: session.baseDirectory)
            if let data = session.archive.data(for: path) { return data }
        }

        if let item = items.values.first(where: {
            $0.mediaType.hasPrefix("image/") && $0.href.lowercased().contains("cover")
        }) {
            let path = resolve(href: item.href, base: session.baseDirectory)
            if let data = session.archive.data(for: path) { return data }
        }

        return nil
    }

    private static func resolve(href: String, base: String) -> String {
        let decoded = EPUBTOC.normalize(href)
        if decoded.hasPrefix("/") { return String(decoded.dropFirst()) }
        if base.isEmpty { return decoded }
        return (base as NSString).appendingPathComponent(decoded)
    }
}

/// 阅读内容的两种形态:重排文本 或 固定版式 PDF
enum ReaderContent {
    case text(BookDocument)
    case pdf(URL)
}

enum DocumentLoader {
    static func load(book: Book, url: URL) throws -> ReaderContent {
        switch book.format {
        case .txt:
            let data = try Data(contentsOf: url)
            return .text(PlainTextParser.parse(data: data, fallbackTitle: book.title))
        case .epub:
            return .text(try EPUBParser.document(url: url, fallbackTitle: book.title))
        case .pdf:
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ParseError.emptyDocument
            }
            return .pdf(url)
        }
    }
}
