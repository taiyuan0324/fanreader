import Foundation
import Combine

@MainActor
final class BookmarkStore: ObservableObject {
    @Published private(set) var bookmarks: [Bookmark] = []

    private let url: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = documents.appendingPathComponent("bookmarks.json")
        load()
    }

    func bookmarks(for bookID: UUID) -> [Bookmark] {
        bookmarks.filter { $0.bookID == bookID }.sorted { $0.createdAt > $1.createdAt }
    }

    func add(_ bookmark: Bookmark) {
        bookmarks.removeAll {
            $0.bookID == bookmark.bookID
                && $0.chapterIndex == bookmark.chapterIndex
                && $0.pageIndex == bookmark.pageIndex
        }
        bookmarks.append(bookmark)
        save()
    }

    func remove(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        save()
    }

    func removeAll(for bookID: UUID) {
        bookmarks.removeAll { $0.bookID == bookID }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
