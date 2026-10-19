import Foundation

/// 记录服务端实际使用的引擎(豆包服务降级到微软时能看出来)。
final class TTSEngineTrace: @unchecked Sendable {
    static let shared = TTSEngineTrace()

    private let lock = NSLock()
    private var value = ""

    private init() {}

    func set(_ engine: String) {
        lock.lock()
        value = engine
        lock.unlock()
    }

    var current: String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
