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

    @State private var chromeVisible = false
    /// 听书态:与阅读态互斥,避免阅读时误触朗读
    @State private var isListening = false
    /// TabView 下标 = 正文页 + 首尾两个跨章占位页
    @State private var displayIndex = 1
    /// 本次朗读所属章节(切章后旧回调一律作废,避免重复跳章)
    @State private var speechChapter = -1
    @State private var showPanel = false
    @State private var showSettings = false
    @State private var scrollOffset: CGFloat = 0
    @State private var speechError: String?
    @State private var lastLoggedChunk = ""
    /// 书签操作后的短暂提示
    @State private var toastText: String?

    private let headerHeight: CGFloat = 26
    private let footerHeight: CGFloat = 44

    init(book: Book, fileURL: URL) {
        _model = StateObject(wrappedValue: ReaderModel(book: book, fileURL: fileURL))
    }

    var body: some View {
        ZStack {
            settings.theme.background.ignoresSafeArea()
            content
            chrome
            toastOverlay
        }
        .overlay(alignment: .leading) { backEdge }
        .simultaneousGesture(pullDownBookmarkGesture)
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

            Group {
                if settings.pageMode == .curl {
                    CurlPager(count: model.pages.count + 2,
                              index: $displayIndex,
                              pageBackground: settings.theme.uiBackground,
                              content: { slot in AnyView(slotView(slot, pageSize: pageSize)) })
                } else {
                    TabView(selection: $displayIndex) {
                        ForEach(0..<(model.pages.count + 2), id: \.self) { slot in
                            slotView(slot, pageSize: pageSize)
                                .tag(slot)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
            .padding(.horizontal, settings.margin)
            .padding(.top, 14)
            .padding(.bottom, 46)
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

    /// 单个槽位:0 = 上一章占位,count+1 = 下一章占位,其余是正文页
    @ViewBuilder
    private func slotView(_ slot: Int, pageSize: CGSize) -> some View {
        if model.pages.isEmpty {
            // 分页还没完成:先给个空白页,别把槽位误判成跨章过渡页
            Color.clear
                .frame(width: pageSize.width, height: pageSize.height)
        } else if slot == 0 {
            chapterBoundary(title: "上一章")
        } else if slot == model.pages.count + 1 {
            chapterBoundary(title: "下一章")
        } else {
            let index = slot - 1
            let page = model.pages.indices.contains(index)
                ? model.pages[index]
                : NSAttributedString(string: "")

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
                    guard isListening else { return }
                    startSpeech(fromPage: index, charIndex: charIndex)
                }
            )
            .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
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
        .padding(.top, 14)
        .padding(.bottom, 46)
        .simultaneousGesture(
            SpatialTapGesture().onEnded { _ in
                withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
            }
        )
    }

    /// 页眉页脚占用的高度,分页时要扣掉,否则最后一页会被裁
    private func pageInsets(full: CGSize) -> CGFloat {
        let chrome: CGFloat = 46
        return full.height * 0.02 + chrome
    }

    // MARK: - 页眉 / 页脚 / 工具条

    @ViewBuilder
    private var chrome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .overlay(alignment: .bottom) {
            bottomBar
        }
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if chromeVisible {
                // 顶部:听书态左侧胶囊 / 阅读态右侧「听」
                HStack {
                    if isListening {
                        listeningPill
                    }
                    Spacer()
                    if !isListening {
                        listenCircle
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)

                chapterSlider
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)

                tabRow
                    .padding(.bottom, 6)
            }

            statusFooter
        }
        .background(settings.theme.background)
        .overlay(alignment: .top) {
            Divider().opacity(chromeVisible ? 0.5 : 0)
        }
    }

    /// 右上角「听」圆钮
    private var listenCircle: some View {
        Button { toggleListening() } label: {
            Text("听")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(Circle().fill(pillColor))
        }
        .buttonStyle(.plain)
    }

    /// 听书态左上角胶囊:封面 + 暂停 + 关闭
    private var listeningPill: some View {
        HStack(spacing: 10) {
            Text(String(model.book.title.prefix(1)))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.25)))

            Button { toggleSpeech() } label: {
                Image(systemName: speech.isSpeaking ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)

            Button { stopListening() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(pillColor.opacity(0.92)))
    }

    /// 上一章 —— 胶囊进度 —— 下一章
    private var chapterSlider: some View {
        HStack(spacing: 12) {
            Button { jumpChapter(-1) } label: {
                Text("上一章").font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(model.chapterIndex <= 0)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(settings.theme.textColor.opacity(0.12))
                        .frame(height: 10)

                    Circle()
                        .fill(.white)
                        .frame(width: 26, height: 26)
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                        .offset(x: max(0, min(geo.size.width - 26,
                                             geo.size.width * CGFloat(model.progress) - 13)))
                }
                .frame(height: 26)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            guard geo.size.width > 0 else { return }
                            let ratio = max(0, min(1, value.location.x / geo.size.width))
                            let target = Int((CGFloat(max(model.pageCount - 1, 1)) * ratio).rounded())
                            model.pageIndex = min(max(target, 0), max(model.pageCount - 1, 0))
                            displayIndex = model.pageIndex + 1
                        }
                )
            }
            .frame(height: 26)

            Button { jumpChapter(1) } label: {
                Text("下一章").font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(model.chapterIndex >= model.chapterCount - 1)
        }
    }

    /// 目录 / 夜间 / 设置 —— 放大到易点按的尺寸
    private var tabRow: some View {
        HStack(spacing: 0) {
            tabButton("目录", "list.bullet") { showPanel = true }
            tabButton("夜间", settings.theme == .dark || settings.theme == .black ? "sun.max" : "moon") {
                toggleNightMode()
            }
            tabButton("设置", "gearshape") { showSettings = true }
        }
        .padding(.horizontal, 8)
    }

    private func tabButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .regular))
                Text(title)
                    .font(.system(size: 13))
            }
            .foregroundStyle(settings.theme.textColor.opacity(0.85))
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 常驻页脚:页码 — 播放胶囊 — 时间电量
    private var statusFooter: some View {
        HStack(spacing: 10) {
            Text("\(model.currentPageNumber)/\(max(model.pageCount, 1))")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(settings.theme.secondaryColor)

            Spacer(minLength: 6)

            footerPill

            Spacer(minLength: 6)

            HStack(spacing: 5) {
                Text(Date(), style: .time)
                    .font(.system(size: 12))
                    .monospacedDigit()
                BatteryLabel()
            }
            .foregroundStyle(settings.theme.secondaryColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    /// 页脚中间胶囊:不在本页时给两个选择,否则给暂停/播放
    @ViewBuilder
    private var footerPill: some View {
        if isListening, !isPlaybackOnCurrentPage {
            HStack(spacing: 10) {
                Button { returnToPlayback() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("原进度")
                    }
                }
                Rectangle().fill(.white.opacity(0.35)).frame(width: 0.8, height: 14)
                Button { listenFromCurrentPage() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "headphones")
                        Text("从本页听")
                    }
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(pillColor.opacity(0.92)))
            .buttonStyle(.plain)
        } else if isListening {
            Button { toggleSpeech() } label: {
                HStack(spacing: 5) {
                    Image(systemName: speech.isSpeaking ? "pause.fill" : "play.fill")
                    Text(speech.isSpeaking ? "暂停播放" : "继续播放")
                }
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(pillColor.opacity(0.92)))
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(height: 30)
        }
    }

    private var pillColor: Color {
        switch settings.theme {
        case .dark, .black:
            return Color(red: 0.72, green: 0.66, blue: 0.55)
        default:
            return Color(red: 0.42, green: 0.36, blue: 0.28)
        }
    }

    private func toggleNightMode() {
        let isDark = settings.theme == .dark || settings.theme == .black
        settings.theme = isDark ? .paper : .dark
    }

    // MARK: - 悬浮球 / 手势 / 提示

    @ViewBuilder
    private var toastOverlay: some View {
        if let toastText {
            Text(toastText)
                .font(.system(size: 13))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(.ultraThinMaterial))
                .offset(y: -120)
                .transition(.opacity)
        }
    }

    /// 左侧 22pt 边缘右滑 = 返回书架
    private var backEdge: some View {
        Color.clear
            .frame(width: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 15)
                    .onEnded { value in
                        guard value.translation.width > 60,
                              abs(value.translation.height) < 90 else { return }
                        persist()
                        dismiss()
                    }
            )
    }

    /// 下拉 = 添加/删除当前页书签(上下滚动模式不启用)
    private var pullDownBookmarkGesture: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                guard settings.pageMode != .scroll, !model.isPDF else { return }
                let dy = value.translation.height
                let dx = value.translation.width
                guard dy > 80, abs(dy) > abs(dx) * 1.6 else { return }
                toggleBookmarkAtCurrentPage()
            }
    }

    private func toggleBookmarkAtCurrentPage() {
        let existing = bookmarkStore.bookmarks(for: model.book.id).first {
            $0.chapterIndex == model.chapterIndex && $0.pageIndex == model.pageIndex
        }
        if let existing {
            bookmarkStore.remove(existing)
            showToast("已删除本页书签")
        } else {
            addBookmark()
            showToast("已添加书签")
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeInOut(duration: 0.15)) { toastText = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeInOut(duration: 0.2)) { toastText = nil }
        }
    }

    // MARK: - 听书位置

    private var playbackPageIndex: Int? {
        guard let range = speech.currentRange else { return nil }
        return model.pageIndex(containing: range.location)
    }

    private var isPlaybackOnCurrentPage: Bool {
        guard let page = playbackPageIndex else { return true }
        return page == model.pageIndex
    }

    private func returnToPlayback() {
        guard let page = playbackPageIndex else { return }
        model.pageIndex = page
        displayIndex = page + 1
    }

    private func listenFromCurrentPage() {
        speakChapter(from: currentPageStartOffset)
    }

    private func stopListening() {
        speech.stop()
        isListening = false
    }

    private func cyclePageMode() {
        let all = ReaderPageMode.allCases
        guard let index = all.firstIndex(of: settings.pageMode) else { return }
        settings.pageMode = all[(index + 1) % all.count]
        showToast(settings.pageMode.name)
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
        guard speech.isSpeaking,
              model.chapterIndex == speechChapter,
              !model.isPDF,
              let range = speech.currentRange else { return }
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

    /// 手动切章(按钮/滑动):必须停掉旧章的朗读,否则旧回调会把页码/章节再改一次
    private func jumpChapter(_ delta: Int, landOnLastPage: Bool = false) {
        speech.stop()
        if delta > 0 {
            model.nextChapter()
        } else {
            model.previousChapter()
        }
        if landOnLastPage {
            model.pageIndex = max(model.pages.count - 1, 0)
        }
        displayIndex = model.pageIndex + 1

        if isListening {
            let offset = landOnLastPage
                ? (model.pageRanges.last?.location ?? 0)
                : 0
            speakChapter(from: offset)
        }
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
            jumpChapter(-1, landOnLastPage: true)
            return
        }

        if index == pageCount + 1 {
            guard model.chapterIndex + 1 < model.chapterCount else {
                displayIndex = pageCount
                return
            }
            jumpChapter(1)
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
        speechChapter = model.chapterIndex

        speech.onError = { error in
            speechError = error.localizedDescription
        }
        speech.onChapterFinished = { [weak controller] in
            guard let controller,
                  settings.autoTurnPageOnSpeech,
                  model.chapterIndex == speechChapter,      // 期间没有被手动切章
                  model.chapterIndex + 1 < model.chapterCount else { return }
            model.nextChapter()
            speechChapter = model.chapterIndex
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
