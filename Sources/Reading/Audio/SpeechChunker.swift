import Foundation

/// 一个朗读片段:文本 + 在章节中的绝对区间。
struct SpeechChunk {
    let text: String
    let range: NSRange
}

/// 按句子切块,同时记录每块在章节文本中的绝对偏移。
/// 这样跨页朗读、预缓存、高亮定位都用同一套坐标,不再依赖字符串匹配。
enum SpeechChunker {
    private static let terminators: Set<unichar> = {
        let chars = "。！？…；!?;\n"
        var set = Set<unichar>()
        chars.utf16.forEach { set.insert($0) }
        return set
    }()

    static func chunks(in text: NSString, from offset: Int, maxLength: Int) -> [SpeechChunk] {
        guard text.length > 0, offset < text.length, maxLength > 8 else { return [] }

        var result: [SpeechChunk] = []
        var start = offset
        var index = offset

        while index < text.length {
            let character = text.character(at: index)
            index += 1

            let hitTerminator = terminators.contains(character) && (index - start) >= 6
            let tooLong = (index - start) >= maxLength

            if hitTerminator || tooLong {
                if let chunk = makeChunk(text: text, range: NSRange(location: start, length: index - start)) {
                    result.append(chunk)
                }
                start = index
            }
        }

        if start < text.length,
           let chunk = makeChunk(text: text, range: NSRange(location: start, length: text.length - start)) {
            result.append(chunk)
        }
        return result
    }

    /// 去掉首尾空白,但保留绝对偏移
    private static func makeChunk(text: NSString, range: NSRange) -> SpeechChunk? {
        var start = range.location
        var end = range.location + range.length

        while start < end, isWhitespace(text.character(at: start)) { start += 1 }
        while end > start, isWhitespace(text.character(at: end - 1)) { end -= 1 }
        guard end > start else { return nil }

        let trimmed = NSRange(location: start, length: end - start)
        return SpeechChunk(text: text.substring(with: trimmed), range: trimmed)
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x0A || character == 0x0D
            || character == 0x09 || character == 0x3000
    }
}
