import SwiftUI
import UIKit

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: ReadingSettings
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var tts: TTSSettings

    enum Sheet: Identifiable {
        case picker
        case settings

        var id: Int {
            switch self {
            case .picker: return 1
            case .settings: return 2
            }
        }
    }

    @State private var sheet: Sheet?
    @State private var selection: Book?
    @State private var keyword = ""
    @State private var onlyFavorites = false
    @State private var errorMessage: String?
    @State private var renameTarget: Book?
    @State private var renameText = ""
    @State private var pendingDelete: Book?
    @State private var isWorking = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)

    var body: some View {
        NavigationStack {
            Group {
                if visibleBooks.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("书架")
            .searchable(text: $keyword, prompt: "搜索书名或作者")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("排序", selection: $library.sortMode) {
                            ForEach(LibraryStore.SortMode.allCases) { mode in
                                Text(mode.name).tag(mode)
                            }
                        }
                        Toggle("只看收藏", isOn: $onlyFavorites)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            sheet = .settings
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        Button {
                            ImportLog.write("tap import (+)")
                            sheet = .picker
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-openFirstBook"),
                   selection == nil,
                   let first = visibleBooks.first {
                    selection = first
                }
            }
            .overlay {
                if isWorking {
                    ZStack {
                        Color.black.opacity(0.15).ignoresSafeArea()
                        ProgressView("正在导入…")
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        // 单一 sheet 通道:同一视图挂多个 .sheet 在 iOS 16 上会互相顶掉
        .sheet(item: $sheet) { item in
            switch item {
            case .picker:
                DocumentPicker(onPick: { urls in
                    sheet = nil
                    importPicked(urls)
                }, onCancel: {
                    sheet = nil
                })
                .ignoresSafeArea()
            case .settings:
                AppSettingsView()
                    .environmentObject(library)
                    .environmentObject(settings)
                    .environmentObject(tts)
            }
        }
        .fullScreenCover(item: $selection) { book in
            ReaderView(book: book, fileURL: library.fileURL(for: book))
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(bookmarks)
                .environmentObject(tts)
        }
        .onOpenURL { url in
            ImportLog.write("onOpenURL: \(url.lastPathComponent)")
            importPicked([url])
        }
        .alert("出错了", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("删除这本书?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let book = pendingDelete {
                    bookmarks.removeAll(for: book.id)
                    library.delete(book)
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
        .alert("重命名", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("书名", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("保存") {
                if let target = renameTarget, !renameText.isEmpty {
                    library.rename(target, to: renameText)
                }
                renameTarget = nil
            }
        }
    }

    // MARK: - 数据

    private var visibleBooks: [Book] {
        var items = library.search(keyword)
        if onlyFavorites {
            items = items.filter { $0.isFavorite }
        }
        return items
    }

    // MARK: - 列表

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(visibleBooks) { book in
                    Button {
                        selection = book
                    } label: {
                        card(for: book)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            library.toggleFavorite(book)
                        } label: {
                            Label(book.isFavorite ? "取消收藏" : "收藏",
                                  systemImage: book.isFavorite ? "star.slash" : "star")
                        }
                        Button {
                            renameText = book.title
                            renameTarget = book
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            pendingDelete = book
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: keyword.isEmpty ? "books.vertical" : "magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(keyword.isEmpty ? "书架是空的" : "没有匹配的书")
                .font(.headline)
            Text(keyword.isEmpty ? "支持 TXT / EPUB / PDF,点右上角 + 导入" : "换个关键词试试")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if keyword.isEmpty {
                VStack(spacing: 8) {
                    Button("导入文件") {
                        ImportLog.write("empty state: tap import")
                        sheet = .picker
                    }
                    .buttonStyle(.borderedProminent)

                    Text("也可以:文件 App 里选中文件 → 共享 → 翻页")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(for book: Book) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            cover(for: book)
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomLeading) {
                    if book.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if book.progress > 0.01 {
                        GeometryReader { proxy in
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.8))
                                .frame(width: proxy.size.width * book.progress, height: 2)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                        .frame(height: 3)
                    }
                }

            Text(book.title)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.primary)
            Text(book.subtitle)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func cover(for book: Book) -> some View {
        if let url = library.coverURL(for: book), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(uiColor: .tertiarySystemFill),
                             Color(uiColor: .secondarySystemBackground)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                VStack(spacing: 8) {
                    Image(systemName: iconName(for: book.format))
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text(book.format.rawValue.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                }
            }
        }
    }

    private func iconName(for format: BookFormat) -> String {
        switch format {
        case .txt: return "doc.text"
        case .epub: return "book.closed"
        case .pdf: return "doc.richtext"
        }
    }

    // MARK: - 导入

    private func importPicked(_ urls: [URL]) {
        ImportLog.write("importPicked count=\(urls.count)")
        guard !urls.isEmpty else {
            errorMessage = "没有拿到文件。可以试试:文件 App 里选中文件 → 共享 → 翻页。"
            return
        }
        isWorking = true
        Task {
            var firstImported: Book?
            var failures: [String] = []
            for url in urls {
                do {
                    let book = try await library.importFile(at: url)
                    if firstImported == nil { firstImported = book }
                } catch {
                    failures.append("\(url.lastPathComponent):\(error.localizedDescription)")
                }
            }
            isWorking = false
            if let book = firstImported {
                selection = library.books.first { $0.id == book.id } ?? book
            }
            if !failures.isEmpty {
                errorMessage = failures.joined(separator: "\n")
            }
        }
    }
}
