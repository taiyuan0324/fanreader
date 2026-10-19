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
    @State private var showPanel = false
    @State private var showSettings = false
    @State private var showThemeQuickBar = false
    @State private var scrollOffset: CGFloat = 0
    @State private var speechError: String?

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
        .onChange(of: speech.currentChunk) { chunk in
            followSpeechChunk(chunk)
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

            TabView(selection: $model.pageIndex) {
                ForEach(Array(model.pages.enumerated()), id: \.offset) { index, page in
                    ZStack {
                        // 只给邻近三页建真正的 UITextView,其余留白:
                        // TabView 会一次性实例化所有子视图,整章几十页会直接把主线程压死
                        if abs(index - model.pageIndex) <= 1 {
                    PagedTextView(
                        attributedText: page,
                        highlightRange: highlightRange(pageIndex: index),
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
                            startSpeech(fromPage: index, charIndex: charIndex)
                        }
                    )
                    .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
                        }
                    }
                    .tag(index)
                }
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
        HStack(spacing: 16) {
            Button {
                persist()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Button {
                addBookmark()
            } label: {
                Image(systemName: "bookmark")
            }
            Button {
                showPanel = true
            } label: {
                Image(systemName: "list.bullet")
            }
            Button {
                showThemeQuickBar.toggle()
            } label: {
                Image(systemName: "circle.lefthalf.filled")
            }
            Button {
                showSettings = true
            } label: {
                Image(systemName: "textformat")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if showThemeQuickBar {
                themeQuickBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            ProgressView(value: model.progress)
                .tint(.accentColor)
                .padding(.horizontal, 20)
                .padding(.top, 6)

            HStack(spacing: 20) {
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
                    HStack(spacing: 4) {
                        Image(systemName: speech.isSpeaking ? "pause.circle.fill" : "play.circle")
                            .font(.title3)
                        if speech.isSpeaking, !speech.activeEngine.isEmpty {
                            Text(speech.activeEngine)
                                .font(.system(size: 9))
                        }
                    }
                }
                .disabled(model.isPDF)

                Spacer()

                Text(speech.isSpeaking && !speech.progressText.isEmpty ? speech.progressText : pageLabel)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    settings.fontSize = max(12, settings.fontSize - 1)
                    withAnimation(.easeInOut(duration: 0.2)) { showThemeQuickBar = false }
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                Button {
                    settings.fontSize = min(32, settings.fontSize + 1)
                    withAnimation(.easeInOut(duration: 0.2)) { showThemeQuickBar = false }
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
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
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

    private var pageLabel: String {
        if model.isPDF || settings.pageMode == .slide {
            return "\(model.currentPageNumber)/\(max(model.pageCount, 1))"
        }
        return "滚动 · \(Int(model.progress * 100))%"
    }

    // MARK: - 交互

    private var highlightColor: UIColor {
        let dark = settings.theme == .dark || settings.theme == .black
        return dark ? UIColor.systemYellow.withAlphaComponent(0.26)
                    : UIColor.systemYellow.withAlphaComponent(0.34)
    }

    /// 当前朗读片段在本页的区间。
    /// 分句时把换行换成了空格,所以这里要容忍空白差异,否则永远匹配不上。
    private func highlightRange(pageIndex: Int) -> NSRange? {
        guard speech.isSpeaking, !speech.currentChunk.isEmpty,
              model.pages.indices.contains(pageIndex) else { return nil }
        return Self.range(of: speech.currentChunk, in: model.pages[pageIndex].string)
    }

    static func range(of chunk: String, in pageText: String) -> NSRange? {
        let text = pageText as NSString
        guard text.length > 0, !chunk.isEmpty else { return nil }

        let direct = text.range(of: chunk)
        if direct.location != NSNotFound { return direct }

        // 空格 ↔ 换行/多空格
        let escaped = NSRegularExpression.escapedPattern(for: chunk)
            .replacingOccurrences(of: "\\ ", with: "\\s+")
        if let regex = try? NSRegularExpression(pattern: escaped),
           let match = regex.firstMatch(in: pageText,
                                        range: NSRange(location: 0, length: text.length)) {
            return match.range
        }

        // 再退一步:用前 10 个字定位
        let prefix = String(chunk.prefix(10))
        let loose = text.range(of: prefix)
        return loose.location == NSNotFound ? nil : loose
    }

    /// 朗读跨页时自动跟到下一页
    private func followSpeechChunk(_ chunk: String) {
        guard speech.isSpeaking, !chunk.isEmpty, !model.isPDF else { return }
        if model.pages.indices.contains(model.pageIndex),
           Self.range(of: chunk, in: model.pages[model.pageIndex].string) != nil {
            return
        }
        guard model.pageIndex + 1 < model.pages.count else { return }
        for index in (model.pageIndex + 1)..<model.pages.count {
            if Self.range(of: chunk, in: model.pages[index].string) != nil {
                model.pageIndex = index
                return
            }
        }
    }

    /// 双击定位:从本页第 charIndex 个字符开始朗读
    private func startSpeech(fromPage page: Int, charIndex: Int) {
        speech.stop()
        guard model.pages.indices.contains(page) else { return }
        if model.pageIndex != page { model.pageIndex = page }

        let string = model.pages[page].string as NSString
        guard string.length > 0 else { return }
        let clamped = min(max(charIndex, 0), string.length - 1)
        var remainder = string.substring(from: clamped)
        remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return }
        speak(remainder)
    }

    private func relayout(pageSize: CGSize) {
        model.relayout(size: pageSize, attributes: settings.textAttributes)
    }

    private func toggleSpeech() {
        if speech.isSpeaking {
            speech.stop()
            return
        }

        let reader = self.model
        let config = settings
        let speechSettings = self.tts
        let controller = speech

        speech.onError = { error in
            speechError = error.localizedDescription
        }
        speech.onPageFinished = { [weak controller] in
            guard let controller, config.autoTurnPageOnSpeech else { return }
            let before = reader.pageIndex
            let beforeChapter = reader.chapterIndex
            reader.nextPage()
            guard reader.pageIndex != before || reader.chapterIndex != beforeChapter,
                  let text = reader.textForSpeech() else { return }
            controller.speak(text,
                             config: SpeechConfig(onlineProvider: speechSettings.provider,
                                                  voice: speechSettings.voice,
                                                  systemVoiceID: speechSettings.systemVoice,
                                                  providerKind: speechSettings.kind,
                                                  providerName: speechSettings.kind == .system
                                                    ? "系统"
                                                    : speechSettings.kind.name,
                                                  prefetch: Int(config.prefetchCount),
                                                  multiplier: config.normalizedMultiplier))
        }

        guard let text = reader.textForSpeech() else { return }
        speak(text)
    }

    private func speak(_ text: String) {
        let config = SpeechConfig(onlineProvider: tts.provider,
                                  voice: tts.voice,
                                  systemVoiceID: tts.systemVoice,
                                  providerKind: tts.kind,
                                  providerName: tts.kind == .system ? "系统" : tts.kind.name,
                                  prefetch: Int(settings.prefetchCount),
                                  multiplier: settings.normalizedMultiplier)
        speech.speak(text, config: config)
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
                Section("主题") {
                    themeGrid
                }

                Section("排版") {
                    fontPicker

                    sliderRow(title: "字号", value: $settings.fontSize, range: 12...32, step: 1, format: "%.0f")
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

                Section("翻页") {
                    Picker("模式", selection: $settings.pageMode) {
                        ForEach(ReaderPageMode.allCases) { mode in
                            Text(mode.name).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("显示页眉页脚", isOn: $settings.showHeaderFooter)
                }

                Section("朗读") {
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
