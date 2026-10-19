import Foundation

enum TextDecoding {
    static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let text = String(data: data, encoding: String.Encoding(rawValue: gb)) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        return String(decoding: data, as: UTF8.self)
    }
}

enum PlainTextParser {
    private static let headingPattern =
        #"(?m)^[ \t]*(第[0-9０-９一二三四五六七八九十百千零〇两]{1,12}[章节回卷篇][^\n]{0,30})$"#

    static func parse(data: Data, fallbackTitle: String) -> BookDocument {
        let text = TextDecoding.decode(data)
        let chapters = split(text)
        return BookDocument(title: fallbackTitle, author: "", chapters: chapters)
    }

    static func split(_ text: String) -> [Chapter] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let regex = try? NSRegularExpression(pattern: headingPattern) else {
            return chunked(normalized)
        }

        let ns = normalized as NSString
        let matches = regex.matches(in: normalized, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return chunked(normalized) }

        var chapters: [Chapter] = []
        var index = 0

        let prefaceEnd = matches[0].range.location
        if prefaceEnd > 200 {
            let preface = ns.substring(with: NSRange(location: 0, length: prefaceEnd))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !preface.isEmpty {
                chapters.append(Chapter(id: index, title: "前言", text: preface))
                index += 1
            }
        }

        for (offset, match) in matches.enumerated() {
            let title = ns.substring(with: match.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let start = match.range.location
            let end = offset + 1 < matches.count ? matches[offset + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(Chapter(id: index, title: title, text: body))
            index += 1
        }

        return chapters.isEmpty ? chunked(normalized) : chapters
    }

    /// 无章节标记:按段落边界切块
    private static func chunked(_ text: String, target: Int = 5000) -> [Chapter] {
        let paragraphs = text.components(separatedBy: "\n")
        var chapters: [Chapter] = []
        var buffer = ""
        var index = 0

        for paragraph in paragraphs {
            buffer += paragraph + "\n"
            if buffer.count >= target {
                chapters.append(Chapter(id: index, title: "第 \(index + 1) 节", text: buffer))
                index += 1
                buffer = ""
            }
        }
        if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chapters.append(Chapter(id: index, title: "第 \(index + 1) 节", text: buffer))
        }
        if chapters.isEmpty {
            chapters = [Chapter(id: 0, title: "全文", text: text)]
        }
        return chapters
    }
}
