import SwiftUI

@main
struct FanReaderApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var settings = ReadingSettings()
    @StateObject private var bookmarks = BookmarkStore()
    @StateObject private var tts = TTSSettings()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(bookmarks)
                .environmentObject(tts)
        }
    }
}
