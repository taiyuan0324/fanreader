import SwiftUI
import UIKit

@MainActor
struct ReaderView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: ReadingSettings
    @EnvironmentObject private var tts: TTSSettings
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: ReaderModel
    @StateObject private var speech = SpeechController()

    @State private var chromeVisible = true
    /// 听书态:与阅读态互斥,避免阅读时误触朗读
    @State private var isListening = false
    /// TabView 下标 = 正文页 + 首尾两个跨章占位页
    @State private var displayIndex = 1
    @State private var showPanel = false
    @State private var showSettings = false
    @State private var showThemeQuickBar = false
    @State private var scrollOffset: CGFloat = 0
    @State private var speechError: String?
    @State private var lastLoggedChunk = ""

    private let headerHeight: CGFloat = 26
    private let footerHeight: CGFloat = 26

    init(book: Book, fileURL: URL) {
        _model = StateObject(wrappedValue: ReaderModel(book: book, fileURL: fileURL))
    }

    var body: some View {
        ZStack {
            settings.theme.background.ignoresSafeArea()
            content
            chrome
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(!chromeVisible)
        .preferredColorScheme(colorScheme)
        .task { await model.load() }
        .onDisappear { persist() }
        .onChange(of: speech.currentRange) { _ in
            followCurrentRange()
        }
        .sheet(isPresented: $showPanel) {
            ReaderPanelView(model: model, bookID: model.book.id)
                .environmentObject(bookmarkStore)
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet()
                .environmentObject(settings)
                .environmentObject(tts)
        }
        .alert("朗读失败", isPresented: Binding(
            get: { speechError != nil },
            set: { if !$0 { speechError = nil } }
        )) {
            Button("好", role: .cancel) { speechError = nil }
        } message: {
            Text(speechError ?? "")
        }
    }

    /// 让系统状态栏、弹层等跟随阅读主题
    private var colorScheme: ColorScheme? {
        switch settings.theme {
        case .dark, .black: return .dark
        case .system: return nil
        default: return .light
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .failed(let message):
            VStack(spacing: 10) {
                Text("打不开这本书").font(.headline)
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        case .ready:
            if let pdf = model.pdfDocument {
                PDFKitView(document: pdf, pageIndex: $model.pdfPageIndex)
                    .highPriorityGesture(TapGesture(count: 2).onEnded { toggleSpeech() })
                    .padding(.vertical, 44)
                    .onChange(of: model.pdfPageIndex) { _ in persist() }
            } else if settings.pageMode == .scroll {
                scrollingContent
            } else {
                pagedContent
            }
        }
    }

    private var pagedContent: some View {
        GeometryReader { proxy in
            let insets = pageInsets(full: proxy.size)
            let pageSize = CGSize(width: max(proxy.size.width - settings.margin * 2, 80),
                                  height: max(proxy.size.height - insets, 80))

            TabView(selection: $displayIndex) {
                chapterBoundary(title: "上一章")
                    .tag(0)

                ForEach(Array(model.pages.enumerated()), id: \.offset) { index, page in
                    CoreTextPage(
                        attributedText: page,
                        highlightRange: localHighlight(pageIndex: index),
                        highlightColor: highlightColor,
                        onSingleTap: { fraction in
                            if fraction < 0.3 {
                                model.previousPage()
                            } else if fraction > 0.7 {
                                model.nextPage()
                            } else {
                                withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
                            }
                        },
                        onDoubleTap: { charIndex in
                            // 只有听书态才响应双击,阅读态保持纯阅读
                            guard isListening else { return }
                            startSpeech(fromPage: index, charIndex: charIndex)
                        }
                    )
                    .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
                    .tag(index + 1)
                }

                chapterBoundary(title: "下一章")
                    .tag(model.pages.count + 1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .padding(.horizontal, settings.margin)
            .padding(.top, settings.showHeaderFooter ? headerHeight + 10 : 12)
            .padding(.bottom, settings.showHeaderFooter ? footerHeight + 6 : 12)
            .onAppear { relayout(pageSize: pageSize) }
            .onChange(of: proxy.size) { newValue in
                let insets = pageInsets(full: newValue)
                let size = CGSize(width: max(newValue.width - settings.margin * 2, 80),
                                  height: max(newValue.height - insets, 80))
                relayout(pageSize: size)
            }
            .onChange(of: settings.fontSize) { _ in relayout(pageSize: pageSize) }
            .onChange(of: settings.fontFamily) { _ in relayout(pageSize: pageSize) }
            .onChange(of: settings.lineHeightMultiple) { _ in relayout(pageSize: pageSize) }
            .onChange(of: settings.paragraphSpacing) { _ in relayout(pageSize: pageSize) }
            .onChange(of: settings.firstLineIndent) { _ in relayout(pageSize: pageSize) }
            .onChange(of: settings.margin) { _ in relayout(pageSize: pageSize) }
            .onChange(of: settings.alignment) { _ in relayout(pageSize: pageSize) }
            .onChange(of: settings.theme) { _ in relayout(pageSize: pageSize) }
            .onChange(of: displayIndex) { newValue in
                handleDisplayIndexChange(newValue)
            }
            .onChange(of: model.pageIndex) { newValue in
                let target = newValue + 1
                if displayIndex != target, target <= model.pages.count {
                    displayIndex = target
                }
            }
        }
    }

    private var scrollingContent: some View {
        ScrollChapterView(
            attributedText: model.chapterAttributedText(attributes: settings.textAttributes)
                ?? NSAttributedString(string: ""),
            backgroundColor: settings.theme.uiBackground,
            scrollOffset: $scrollOffset
        )
        .padding(.horizontal, settings.margin)
        .padding(.top, settings.showHeaderFooter ? headerHeight + 10 : 12)
        .padding(.bottom, settings.showHeaderFooter ? footerHeight + 6 : 12)
        .simultaneousGesture(
            SpatialTapGesture().onEnded { _ in
                withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
            }
        )
    }

    /// 页眉页脚占用的高度,分页时要扣掉,否则最后一页会被裁
    private func pageInsets(full: CGSize) -> CGFloat {
        let chrome = settings.showHeaderFooter ? (headerHeight + footerHeight) : 16
        return full.height * 0.02 + chrome
    }

    // MARK: - 页眉 / 页脚 / 工具条

    @ViewBuilder
    private var chrome: some View {
        VStack(spacing: 0) {
            if settings.showHeaderFooter && !chromeVisible {
                headerBar
            }
            Spacer(minLength: 0)
            if settings.showHeaderFooter && !chromeVisible {
                footerBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .overlay(alignment: .top) {
            if chromeVisible { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .overlay(alignment: .bottom) {
            if chromeVisible { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
    }

    private var headerBar: some View {
        HStack {
            Text(model.book.title)
                .font(.system(size: 10))
                .foregroundStyle(settings.theme.secondaryColor)
                .lineLimit(1)
            Spacer()
            Text(model.chapterTitle)
                .font(.system(size: 10))
                .foregroundStyle(settings.theme.secondaryColor)
                .lineLimit(1)
        }
        .padding(.horizontal, settings.margin)
        .frame(height: headerHeight)
        .allowsHitTesting(false)
    }

    private var footerBar: some View {
        HStack {
            Text(model.isPDF ? "PDF" : "第 \(model.chapterIndex + 1)/\(max(model.chapterCount, 1)) 章")
                .font(.system(size: 10))
                .foregroundStyle(settings.theme.secondaryColor)
            Spacer()
            Text(model.isPDF
                 ? "\(model.currentPageNumber)/\(max(model.pageCount, 1))"
                 : "\(model.currentPageNumber)/\(max(model.pageCount, 1))  ·  \(Int(model.progress * 100))%")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(settings.theme.secondaryColor)
        }
        .padding(.horizontal, settings.margin)
        .frame(height: footerHeight)
        .allowsHitTesting(false)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                persist()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .medium))
            }

            Button {
                showPanel = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .semibold))
                    Text("第\(model.chapterIndex + 1)章 \(model.book.title)")
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .foregroundStyle(settings.theme.textColor.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(Color.primary.opacity(0.06))
                )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            Button {
                toggleListening()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isListening ? "waveform" : "headphones")
                        .font(.system(size: 11, weight: .semibold))
                    Text(isListening ? "听书中" : "听书")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(isListening ? Color.accentColor : settings.theme.textColor.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isListening
                                   ? Color.accentColor.opacity(0.16)
                                   : Color.primary.opacity(0.06))
                )
            }
            .buttonStyle(.plain)

            Button {
                showSettings = true
            } label: {
                Image(systemName: "textformat")
                    .font(.system(size: 15))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if isListening {
                listeningBar
            }

            if chromeVisible {
                ProgressView(value: model.progress)
                    .tint(.accentColor)
                    .padding(.horizontal, 18)
                    .padding(.top, 6)

                HStack(spacing: 22) {
                    Button {
                        model.previousChapter()
                        persist()
                    } label: {
                        Image(systemName: "chevron.left.2")
                    }
                    .disabled(model.isPDF || model.chapterIndex == 0)

                    Button {
                        toggleSpeech()
                    } label: {
                        Image(systemName: speech.isSpeaking ? "pause.circle.fill" : "play.circle")
                            .font(.title3)
                    }
                    .disabled(model.isPDF || !isListening)

                    Spacer()

                    Button {
                        settings.fontSize = max(12, settings.fontSize - 1)
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                    }
                    Button {
                        settings.fontSize = min(32, settings.fontSize + 1)
                    } label: {
                        Image(systemName: "textformat.size.larger")
                    }

                    Button {
                        model.nextChapter()
                        persist()
                    } label: {
                        Image(systemName: "chevron.right.2")
                    }
                    .disabled(model.isPDF || model.chapterIndex >= model.chapterCount - 1)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            }

            // 常驻状态行(参考图底部:左页码 / 右时间)
            HStack {
                Text(model.isPDF ? "\(model.currentPageNumber)/\(max(model.pageCount, 1))"
                                 : "\(model.currentPageNumber)/\(max(model.pageCount, 1))")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(settings.theme.secondaryColor)

                Spacer()

                if isListening {
                    Text(speechLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(settings.theme.secondaryColor)
                    Spacer()
                }

                Text(Date(), style: .time)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(settings.theme.secondaryColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
        }
        .background(.ultraThinMaterial)
    }

    /// 听书态:上一章 / 暂停 / 下一章
    private var listeningBar: some View {
        HStack(spacing: 0) {
            Button {
                model.previousChapter()
                persist()
            } label: {
                Text("上一章").font(.system(size: 12))
            }
            .frame(maxWidth: .infinity)
            .disabled(model.chapterIndex == 0)

            Button {
                toggleSpeech()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: speech.isSpeaking ? "pause.fill" : "play.fill")
                        .font(.system(size: 11))
                    Text(speech.isSpeaking ? "暂停播放" : "继续播放")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.primary.opacity(0.10)))
            }
            .buttonStyle(.plain)

            Button {
                model.nextChapter()
                persist()
            } label: {
                Text("下一章").font(.system(size: 12))
            }
            .frame(maxWidth: .infinity)
            .disabled(model.chapterIndex >= model.chapterCount - 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var themeQuickBar: some View {
        HStack(spacing: 10) {
            ForEach(ReaderTheme.allCases) { theme in
                Button {
                    settings.theme = theme
                } label: {
                    Circle()
                        .fill(theme.background)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(Color.primary.opacity(theme == settings.theme ? 0.9 : 0.15),
                                                 lineWidth: theme == settings.theme ? 2 : 1))
                        .overlay(
                            Text("A")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.textColor)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button {
                withAnimation { showThemeQuickBar = false }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    /// 底栏文案:朗读中显示进度
    private var speechLabel: String {
        guard speech.isSpeaking, !speech.progressText.isEmpty else { return pageLabel }
        return speech.progressText
    }

    private var pageLabel: String {
        if model.isPDF || settings.pageMode == .slide {
            return "\(model.currentPageNumber)/\(max(model.pageCount, 1))"
        }
        return "滚动 · \(Int(model.progress * 100))%"
    }

    // MARK: - 交互

    private var highlightColor: UIColor {
        settings.theme.highlightColor
    }

    /// 当前朗读块在本页的高亮区间(绝对区间裁剪到本页)
    private func localHighlight(pageIndex: Int) -> NSRange? {
        guard speech.isSpeaking, let range = speech.currentRange else { return nil }
        return model.localRange(forPage: pageIndex, absolute: range)
    }

    /// 朗读跨页时自动翻到对应页
    private func followCurrentRange() {
        guard speech.isSpeaking, !model.isPDF, let range = speech.currentRange else { return }
        guard let page = model.pageIndex(containing: range.location) else { return }
        if page != model.pageIndex {
            model.pageIndex = page
        }
    }

    /// 双击:从本页第 charIndex 个字符所在位置开始朗读
    private func startSpeech(fromPage page: Int, charIndex: Int) {
        guard isListening else { return }
        guard let absolute = model.absoluteOffset(pageIndex: page, charIndex: charIndex) else { return }
        speakChapter(from: absolute)
    }

    /// 滑到首/尾的占位页时切换到相邻章节
    private func handleDisplayIndexChange(_ index: Int) {
        let pageCount = model.pages.count
        if pageCount == 0 { return }

        if index == 0 {
            guard model.chapterIndex > 0 else {
                displayIndex = 1
                return
            }
            model.previousChapter()
            displayIndex = max(1, model.pages.count)
            return
        }

        if index == pageCount + 1 {
            guard model.chapterIndex + 1 < model.chapterCount else {
                displayIndex = pageCount
                return
            }
            model.nextChapter()
            displayIndex = 1
            return
        }

        model.pageIndex = max(0, min(index - 1, pageCount - 1))
    }

    private func chapterBoundary(title: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(settings.theme.secondaryColor)
            Text("继续滑动")
                .font(.system(size: 11))
                .foregroundStyle(settings.theme.secondaryColor.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 进入/退出听书态
    private func toggleListening() {
        if isListening {
            speech.stop()
            isListening = false
        } else {
            isListening = true
            speakChapter(from: currentPageStartOffset)
        }
    }

    private var currentPageStartOffset: Int {
        model.pageRanges.indices.contains(model.pageIndex) ? model.pageRanges[model.pageIndex].location : 0
    }

    /// 从章节绝对偏移开始朗读,整章连读(预缓存跨页连续)
    private func speakChapter(from offset: Int) {
        let text = model.chapterText
        guard !text.isEmpty else { return }
        let controller = speech

        speech.onError = { error in
            speechError = error.localizedDescription
        }
        speech.onChapterFinished = { [weak controller] in
            guard let controller,
                  settings.autoTurnPageOnSpeech,
                  model.chapterIndex + 1 < model.chapterCount else { return }
            model.nextChapter()
            controller.speakChapter(model.chapterText,
                                    from: 0,
                                    config: SpeechConfig(onlineProvider: tts.provider,
                                                         voice: tts.voice,
                                                         systemVoiceID: tts.systemVoice,
                                                         providerKind: tts.kind,
                                                         providerName: tts.kind == .system ? "系统" : tts.kind.name,
                                                         prefetch: Int(settings.prefetchCount),
                                                         multiplier: settings.normalizedMultiplier))
        }

        speech.speakChapter(text,
                            from: offset,
                            config: SpeechConfig(onlineProvider: tts.provider,
                                                 voice: tts.voice,
                                                 systemVoiceID: tts.systemVoice,
                                                 providerKind: tts.kind,
                                                 providerName: tts.kind == .system ? "系统" : tts.kind.name,
                                                 prefetch: Int(settings.prefetchCount),
                                                 multiplier: settings.normalizedMultiplier))
    }

    private func relayout(pageSize: CGSize) {
        model.relayout(size: pageSize, attributes: settings.textAttributes)
        // 分页重建后同步 TabView 下标(正文页 + 1)
        let target = model.pageIndex + 1
        if displayIndex != target, target <= model.pages.count {
            displayIndex = target
        }
    }

    private func toggleSpeech() {
        if speech.isSpeaking {
            speech.stop()
            return
        }
        guard isListening else { return }
        speakChapter(from: currentPageStartOffset)
    }

    private func addBookmark() {
        let snippet: String
        if let page = model.textForSpeech() {
            snippet = String(page.prefix(40)).replacingOccurrences(of: "\n", with: " ")
        } else {
            snippet = model.chapterTitle
        }
        bookmarkStore.add(Bookmark(bookID: model.book.id,
                                   chapterIndex: model.chapterIndex,
                                   pageIndex: model.pageIndex,
                                   chapterTitle: model.chapterTitle,
                                   snippet: snippet))
    }

    private func persist() {
        speech.stop()
        isListening = false
        library.update(model.snapshotBook())
    }
}

// MARK: - 目录 / 书签 / 搜索

struct ReaderPanelView: View {
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: ReaderModel
    let bookID: UUID

    enum Tab: String, CaseIterable, Identifiable {
        case toc
        case bookmarks
        case search

        var id: String { rawValue }

        var name: String {
            switch self {
            case .toc: return "目录"
            case .bookmarks: return "书签"
            case .search: return "搜索"
            }
        }
    }

    @State private var tab: Tab = .toc
    @State private var keyword = ""
    @State private var hits: [SearchHit] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { item in
                        Text(item.name).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                switch tab {
                case .toc: tocList
                case .bookmarks: bookmarkList
                case .search: searchView
                }
            }
            .navigationTitle("阅读导航")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var tocList: some View {
        if model.isPDF {
            List {
                if model.outline.isEmpty {
                    Text("这个 PDF 没有内置书签目录")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.outline) { item in
                    Button {
                        if item.pageIndex >= 0 { model.pdfPageIndex = item.pageIndex }
                        dismiss()
                    } label: {
                        HStack {
                            Text(item.title)
                                .lineLimit(1)
                                .padding(.leading, CGFloat(item.level) * 12)
                            Spacer()
                            if item.pageIndex >= 0 {
                                Text("\(item.pageIndex + 1)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        } else {
            List {
                if let document = model.document {
                    ForEach(document.chapters) { chapter in
                        Button {
                            model.goToChapter(chapter.id)
                            dismiss()
                        } label: {
                            HStack {
                                Text(chapter.title).lineLimit(1)
                                Spacer()
                                if chapter.id == model.chapterIndex {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var bookmarkList: some View {
        let items = bookmarkStore.bookmarks(for: bookID)
        return List {
            if items.isEmpty {
                Text("还没有书签,阅读时点右上角书签按钮添加")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { bookmark in
                Button {
                    model.goToChapter(bookmark.chapterIndex)
                    model.pageIndex = min(bookmark.pageIndex, max(model.pages.count - 1, 0))
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(bookmark.chapterTitle).font(.subheadline)
                        Text(bookmark.snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        bookmarkStore.remove(bookmark)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var searchView: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜索全书", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { hits = model.search(keyword) }
                Button("搜索") { hits = model.search(keyword) }
                    .disabled(keyword.isEmpty)
            }
            .padding(16)

            List(hits) { hit in
                Button {
                    model.jump(to: hit)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hit.chapterTitle).font(.caption).foregroundStyle(.secondary)
                        Text(hit.snippet).font(.subheadline).lineLimit(3)
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - 阅读内设置

struct ReaderSettingsSheet: View {
    @EnvironmentObject private var settings: ReadingSettings
    @EnvironmentObject private var tts: TTSSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "sun.min")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { Double(UIScreen.main.brightness) },
                            set: { UIScreen.main.brightness = CGFloat($0) }
                        ), in: 0.05...1.0)
                        Image(systemName: "sun.max")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("字体") {
                    HStack(spacing: 14) {
                        Button {
                            settings.fontSize = max(12, settings.fontSize - 1)
                        } label: {
                            Text("A-").font(.system(size: 15))
                        }
                        .buttonStyle(.bordered)

                        Text("\(Int(settings.fontSize))")
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .frame(minWidth: 30)

                        Button {
                            settings.fontSize = min(32, settings.fontSize + 1)
                        } label: {
                            Text("A+").font(.system(size: 17))
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Picker("", selection: $settings.fontFamily) {
                            ForEach(ReaderFontFamily.allCases) { family in
                                Text(family.name).tag(family)
                            }
                        }
                        .labelsHidden()
                    }
                }

                Section("颜色") {
                    themeGrid
                }

                Section("翻页") {
                    Picker("模式", selection: $settings.pageMode) {
                        ForEach(ReaderPageMode.allCases) { mode in
                            Text(mode.name).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("显示页眉页脚", isOn: $settings.showHeaderFooter)
                }

                Section("间距") {
                    sliderRow(title: "行高", value: $settings.lineHeightMultiple,
                              range: 1.1...2.4, step: 0.05, format: "%.2f×")
                    sliderRow(title: "段间距", value: $settings.paragraphSpacing, range: 0...24, step: 1, format: "%.0f")
                    sliderRow(title: "首行缩进", value: $settings.firstLineIndent, range: 0...3, step: 0.5, format: "%.1f字")
                    sliderRow(title: "页边距", value: $settings.margin, range: 8...44, step: 2, format: "%.0f")

                    Picker("对齐", selection: $settings.alignment) {
                        ForEach(ReaderTextAlignment.allCases) { item in
                            Text(item.name).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("听书") {
                    HStack {
                        Text("引擎")
                        Spacer()
                        Text(tts.kind.name).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("状态")
                        Spacer()
                        Text(tts.isConfigured ? "已配置" : "未配置(将用系统语音)")
                            .foregroundStyle(tts.isConfigured ? .green : .orange)
                    }
                    sliderRow(title: "倍速", value: $settings.speechRateMultiplier,
                              range: 1.0...3.0, step: 0.1, format: "%.1f×")
                    sliderRow(title: "预缓存段数", value: $settings.prefetchCount,
                              range: 5...15, step: 1, format: "%.0f 段")
                    Toggle("读完自动翻页", isOn: $settings.autoTurnPageOnSpeech)
                    Text("在线语音在 设置 → 语音合成 里配置")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var themeGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            ForEach(ReaderTheme.allCases) { theme in
                Button {
                    settings.theme = theme
                } label: {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.background)
                            .frame(height: 46)
                            .overlay(
                                Text("Aa")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(theme.textColor)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(theme == settings.theme ? 0.85 : 0.12),
                                            lineWidth: theme == settings.theme ? 2 : 1)
                            )
                        Text(theme.name)
                            .font(.system(size: 10))
                            .foregroundStyle(settings.theme == theme ? Color.accentColor : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private var fontPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ReaderFontFamily.allCases) { family in
                    Button {
                        settings.fontFamily = family
                    } label: {
                        Text(family.name)
                            .font(Font(family.uiFont(ofSize: 14)))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(settings.fontFamily == family
                                          ? Color.accentColor.opacity(0.16)
                                          : Color(uiColor: .secondarySystemBackground))
                            )
                            .foregroundStyle(settings.fontFamily == family ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func sliderRow(title: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           step: Double,
                           format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
