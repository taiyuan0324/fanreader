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
    /// 每页在章节文本中的绝对区间,与 pages 一一对应
    @Published private(set) var pageRanges: [NSRange] = []
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

        layoutSize = size
        layoutAttributes = attributes
        cachedChapterText = chapter.text
        keepPageAfterPagination = keepPage
        schedulePagination(chapter: chapter)
    }

    private func rebuildPages(chapter: Chapter,
                              attributes: [NSAttributedString.Key: Any],
                              size: CGSize) {
        let attributed = NSAttributedString(string: chapter.text, attributes: attributes)
        let ranges = Paginator.ranges(attributed: attributed, size: size)
        let full = chapter.text as NSString

        pageRanges = ranges
        pages = ranges.enumerated().map { index, range in
            var slice = NSMutableAttributedString(attributedString: attributed.attributedSubstring(from: range))

            // 续页(不是段落开头)去掉首行缩进,否则一段话被分页后会看起来像两段
            if range.location > 0 {
                let previous = full.substring(with: NSRange(location: range.location - 1, length: 1))
                if previous != "\n" {
                    let whole = NSRange(location: 0, length: slice.length)
                    slice.enumerateAttribute(.paragraphStyle, in: whole) { value, attrRange, _ in
                        guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                        style.firstLineHeadIndent = 0
                        slice.addAttribute(.paragraphStyle, value: style, range: attrRange)
                    }
                }
            }
            _ = index
            return slice
        }
    }

    /// 上下滚动模式不需要分页,直接给出整章富文本
    func chapterAttributedText(attributes: [NSAttributedString.Key: Any]) -> NSAttributedString? {
        guard let chapter = currentChapter else { return nil }
        return NSAttributedString(string: chapter.text, attributes: attributes)
    }

    // MARK: - 邻章预览(无缝翻章用)

    private var previewCache: [String: NSAttributedString] = [:]

    func chapterTitle(offset: Int) -> String? {
        guard let document else { return nil }
        let index = chapterIndex + offset
        guard document.chapters.indices.contains(index) else { return nil }
        return document.chapters[index].title
    }

    /// 取相邻章节的首页/末页,作为翻页的目标页(不再是"继续滑动"占位)
    func previewPage(offset: Int,
                     last: Bool,
                     size: CGSize,
                     attributes: [NSAttributedString.Key: Any]) -> NSAttributedString? {
        guard let document, size.width > 1, size.height > 1 else { return nil }
        let index = chapterIndex + offset
        guard document.chapters.indices.contains(index) else { return nil }

        let key = "\(offset):\(last ? "last" : "first")"
        if let cached = previewCache[key] { return cached }

        let attributed = NSAttributedString(string: document.chapters[index].text, attributes: attributes)
        let ranges = Paginator.ranges(attributed: attributed, size: size)
        guard let range = last ? ranges.last : ranges.first else { return nil }

        let page = NSAttributedString(attributedString: attributed.attributedSubstring(from: range))
        previewCache[key] = page
        return page
    }

    func clearPreviewCache() { previewCache.removeAll() }

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
        guard let chapter = currentChapter else {
            pages = []
            pageRanges = []
            return
        }
        cachedChapterText = chapter.text
        clearPreviewCache()
        schedulePagination(chapter: chapter)
    }

    // MARK: - 后台分页

    private var paginationTask: Task<Void, Never>?
    private var keepPageAfterPagination = true
    private(set) var previewStamp = 0

    /// 整章分页 + 邻章预览全部在后台算,主线程只收 NSRange 与成品子串
    private func schedulePagination(chapter: Chapter) {
        paginationTask?.cancel()
        guard layoutSize != .zero,
              let attributes = layoutAttributes else { return }
        let size = layoutSize

        let previousIndex = pageIndex
        let keepPage = keepPageAfterPagination
        keepPageAfterPagination = true

        // 邻章文本一起带进后台
        let document = self.document
        let chapterIndex = chapterIndex
        let prevText: String? = {
            guard let document, document.chapters.indices.contains(chapterIndex - 1) else { return nil }
            return document.chapters[chapterIndex - 1].text
        }()
        let nextText: String? = {
            guard let document, document.chapters.indices.contains(chapterIndex + 1) else { return nil }
            return document.chapters[chapterIndex + 1].text
        }()

        paginationTask = Task { [weak self] in
            let ranges = await Paginator.rangesAsync(text: chapter.text,
                                                     attributes: attributes,
                                                     size: size)
            guard !Task.isCancelled else { return }

            // 邻章只取首页/末页,一并预渲染,翻到章末零停顿
            var previousPage: NSAttributedString?
            var nextPage: NSAttributedString?
            if let prevText {
                let r = await Paginator.rangesAsync(text: prevText, attributes: attributes, size: size)
                if let last = r.last {
                    let full = NSAttributedString(string: prevText, attributes: attributes)
                    previousPage = full.attributedSubstring(from: last)
                }
            }
            if let nextText {
                let r = await Paginator.rangesAsync(text: nextText, attributes: attributes, size: size)
                if let first = r.first {
                    let full = NSAttributedString(string: nextText, attributes: attributes)
                    nextPage = full.attributedSubstring(from: first)
                }
            }
            guard !Task.isCancelled else { return }

            let full = NSAttributedString(string: chapter.text, attributes: attributes)
            let fullText = chapter.text as NSString

            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.apply(ranges: ranges,
                           full: full,
                           fullText: fullText,
                           previousPage: previousPage,
                           nextPage: nextPage,
                           targetPageIndex: keepPage ? previousIndex : 0)
            }
        }
    }

    @MainActor
    private func apply(ranges: [NSRange],
                       full: NSAttributedString,
                       fullText: NSString,
                       previousPage: NSAttributedString?,
                       nextPage: NSAttributedString?,
                       targetPageIndex: Int) {
        pageRanges = ranges
        pages = ranges.map { range in
            let slice = NSMutableAttributedString(attributedString: full.attributedSubstring(from: range))
            if range.location > 0 {
                let before = fullText.substring(with: NSRange(location: range.location - 1, length: 1))
                if before != "\n" {
                    let whole = NSRange(location: 0, length: slice.length)
                    slice.enumerateAttribute(.paragraphStyle, in: whole) { value, attrRange, _ in
                        guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                        style.firstLineHeadIndent = 0
                        slice.addAttribute(.paragraphStyle, value: style, range: attrRange)
                    }
                }
            }
            return slice
        }

        previewCache = [:]
        if let previousPage { previewCache["-1:last"] = previousPage }
        if let nextPage { previewCache["1:first"] = nextPage }
        previewStamp += 1

        pageIndex = min(targetPageIndex, max(pages.count - 1, 0))
        if landOnLastPageAfterPagination {
            landOnLastPageAfterPagination = false
            pageIndex = max(pages.count - 1, 0)
        }
    }

    /// 上一章落地在末页(异步分页完成后生效)
    private var landOnLastPageAfterPagination = false

    func previousChapter(landOnLastPage: Bool) {
        landOnLastPageAfterPagination = landOnLastPage
        goToChapter(chapterIndex - 1)
    }

    // MARK: - 坐标映射(朗读/高亮共用)

    var chapterText: String { currentChapter?.text ?? "" }

    /// 全书进度(跨章累计),用于页脚右侧显示
    var bookProgress: Double {
        guard chapterCount > 0 else { return 0 }
        let base = Double(chapterIndex) / Double(chapterCount)
        return min(1, base + progress / Double(chapterCount))
    }

    /// 页内字符下标 → 章节绝对偏移
    func absoluteOffset(pageIndex: Int, charIndex: Int) -> Int? {
        guard pageRanges.indices.contains(pageIndex) else { return nil }
        let range = pageRanges[pageIndex]
        let clamped = min(max(charIndex, 0), range.length)
        return range.location + clamped
    }

    /// 绝对偏移落在第几页
    func pageIndex(containing offset: Int) -> Int? {
        pageRanges.firstIndex { NSLocationInRange(offset, $0) }
            ?? pageRanges.lastIndex { offset == $0.location + $0.length }
    }

    /// 绝对区间 → 当前页的局部区间(用于高亮)
    func localRange(forPage index: Int, absolute: NSRange) -> NSRange? {
        guard pageRanges.indices.contains(index) else { return nil }
        let page = pageRanges[index]
        let start = max(absolute.location, page.location)
        let end = min(absolute.location + absolute.length, page.location + page.length)
        guard start < end else { return nil }
        return NSRange(location: start - page.location, length: end - start)
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
