import SwiftUI
import UIKit
import PDFKit

struct OutlineItem: Identifiable {
    let id = UUID()
    let title: String
    let pageIndex: Int
    let level: Int
}

@MainActor
final class ReaderModel: ObservableObject {
    enum State: Equatable {
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var document: BookDocument?
    @Published private(set) var pdfDocument: PDFDocument?
    @Published private(set) var pages: [NSAttributedString] = []
    @Published var chapterIndex = 0
    @Published var pageIndex = 0
    @Published var pdfPageIndex = 0
    @Published private(set) var outline: [OutlineItem] = []

    let book: Book
    let fileURL: URL

    private var layoutSize: CGSize = .zero
    private var layoutAttributes: [NSAttributedString.Key: Any]?
    private var cachedChapterText: String = ""

    init(book: Book, fileURL: URL) {
        self.book = book
        self.fileURL = fileURL
        self.chapterIndex = book.chapterIndex
        self.pageIndex = book.pageIndex
    }

    // MARK: - 派生状态

    var isPDF: Bool { pdfDocument != nil }

    var chapterCount: Int { document?.chapters.count ?? 0 }

    var currentChapter: Chapter? {
        guard let document, document.chapters.indices.contains(chapterIndex) else { return nil }
        return document.chapters[chapterIndex]
    }

    var chapterTitle: String {
        if isPDF { return book.title }
        return currentChapter?.title ?? book.title
    }

    var pageCount: Int { isPDF ? (pdfDocument?.pageCount ?? 0) : pages.count }

    var currentPageNumber: Int { isPDF ? pdfPageIndex + 1 : pageIndex + 1 }

    var progress: Double {
        if isPDF {
            let total = max(pdfDocument?.pageCount ?? 0, 1)
            return min(1, Double(pdfPageIndex + 1) / Double(total))
        }
        guard chapterCount > 0 else { return 0 }
        let base = Double(chapterIndex) / Double(chapterCount)
        let inner = pages.isEmpty ? 0 : Double(pageIndex + 1) / Double(pages.count) / Double(chapterCount)
        return min(1, base + inner)
    }

    // MARK: - 加载

    func load() async {
        state = .loading
        let book = self.book
        let url = self.fileURL
        do {
            let content = try await Task.detached(priority: .userInitiated) {
                try DocumentLoader.load(book: book, url: url)
            }.value

            switch content {
            case .text(let loaded):
                document = loaded
                chapterIndex = min(max(chapterIndex, 0), max(loaded.chapters.count - 1, 0))
                state = .ready
            case .pdf(let pdfURL):
                guard let pdf = PDFDocument(url: pdfURL) else {
                    state = .failed("PDF 无法解析")
                    return
                }
                pdfDocument = pdf
                pdfPageIndex = min(max(book.pageIndex, 0), max(pdf.pageCount - 1, 0))
                outline = buildOutline(from: pdf)
                state = .ready
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func buildOutline(from document: PDFDocument) -> [OutlineItem] {
        var items: [OutlineItem] = []
        func walk(_ node: PDFOutline?, level: Int) {
            guard let node, level < 8 else { return }
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                let pageIndex: Int
                if let page = child.destination?.page {
                    pageIndex = document.index(for: page)
                } else {
                    pageIndex = -1
                }
                items.append(OutlineItem(title: child.label ?? "未命名",
                                         pageIndex: pageIndex,
                                         level: level))
                walk(child, level: level + 1)
            }
        }
        walk(document.outlineRoot, level: 0)
        return items
    }

    // MARK: - 排版

    func relayout(size: CGSize, attributes: [NSAttributedString.Key: Any], keepPage: Bool = true) {
        guard size.width > 1, size.height > 1, let chapter = currentChapter else { return }

        let sameSize = size == layoutSize
        let sameAttributes = NSDictionary(dictionary: attributes).isEqual(to: layoutAttributes ?? [:])
        if sameSize, sameAttributes, !pages.isEmpty, cachedChapterText == chapter.text { return }

        let previous = pageIndex
        layoutSize = size
        layoutAttributes = attributes
        cachedChapterText = chapter.text

        pages = paginate(chapter: chapter, attributes: attributes, size: size)
        pageIndex = keepPage ? min(previous, max(pages.count - 1, 0)) : 0
    }

    private func paginate(chapter: Chapter,
                          attributes: [NSAttributedString.Key: Any],
                          size: CGSize) -> [NSAttributedString] {
        let attributed = NSAttributedString(string: chapter.text, attributes: attributes)
        return Paginator.pages(attributed: attributed, size: size)
    }

    /// 上下滚动模式不需要分页,直接给出整章富文本
    func chapterAttributedText(attributes: [NSAttributedString.Key: Any]) -> NSAttributedString? {
        guard let chapter = currentChapter else { return nil }
        return NSAttributedString(string: chapter.text, attributes: attributes)
    }

    // MARK: - 导航

    func goToChapter(_ index: Int) {
        guard let document, document.chapters.indices.contains(index) else { return }
        chapterIndex = index
        pageIndex = 0
        rebuildPages()
    }

    func nextChapter() { goToChapter(chapterIndex + 1) }
    func previousChapter() { goToChapter(chapterIndex - 1) }

    func nextPage() {
        guard !isPDF else {
            if pdfPageIndex + 1 < (pdfDocument?.pageCount ?? 0) { pdfPageIndex += 1 }
            return
        }
        if pageIndex + 1 < pages.count {
            pageIndex += 1
        } else if chapterIndex + 1 < chapterCount {
            chapterIndex += 1
            pageIndex = 0
            rebuildPages()
        }
    }

    func previousPage() {
        guard !isPDF else {
            if pdfPageIndex > 0 { pdfPageIndex -= 1 }
            return
        }
        if pageIndex > 0 {
            pageIndex -= 1
        } else if chapterIndex > 0 {
            chapterIndex -= 1
            rebuildPages()
            pageIndex = max(pages.count - 1, 0)
        }
    }

    private func rebuildPages() {
        guard let chapter = currentChapter, layoutSize != .zero, let attributes = layoutAttributes else {
            pages = []
            return
        }
        cachedChapterText = chapter.text
        pages = paginate(chapter: chapter, attributes: attributes, size: layoutSize)
        pageIndex = min(pageIndex, max(pages.count - 1, 0))
    }

    // MARK: - 搜索

    func search(_ keyword: String, limit: Int = 80) -> [SearchHit] {
        guard let document else { return [] }
        let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        var hits: [SearchHit] = []
        for chapter in document.chapters {
            guard hits.count < limit else { break }
            var searchRange = chapter.text.startIndex..<chapter.text.endIndex
            while hits.count < limit {
                guard let found = chapter.text.range(of: needle,
                                                     options: [.caseInsensitive, .diacriticInsensitive],
                                                     range: searchRange) else { break }
                hits.append(SearchHit(chapterIndex: chapter.id,
                                      chapterTitle: chapter.title,
                                      snippet: snippet(text: chapter.text, around: found)))
                searchRange = found.upperBound..<chapter.text.endIndex
            }
        }
        return hits
    }

    func jump(to hit: SearchHit) {
        goToChapter(hit.chapterIndex)
        if let index = Paginator.pageIndex(containing: hit.snippet, in: pages) {
            pageIndex = index
        }
    }

    private func snippet(text: String, around range: Range<String.Index>, padding: Int = 22) -> String {
        let start = text.index(range.lowerBound, offsetBy: -padding, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: padding, limitedBy: text.endIndex) ?? text.endIndex
        return text[start..<end]
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 进度 / 朗读

    func snapshotBook() -> Book {
        var updated = book
        updated.chapterIndex = chapterIndex
        updated.pageIndex = isPDF ? pdfPageIndex : pageIndex
        updated.progress = progress
        updated.chapterTitle = chapterTitle
        updated.lastOpenedAt = Date()
        return updated
    }

    func textForSpeech() -> String? {
        guard !isPDF, pages.indices.contains(pageIndex) else { return nil }
        return pages[pageIndex].string
    }
}
