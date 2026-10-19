import Foundation

/// 解析 EPUB 目录:EPUB3 的 nav.xhtml 或 EPUB2 的 NCX。
/// 返回 "章节文件路径 -> 标题" 的映射。
enum EPUBTOC {
    static func parseNavigation(_ html: String) -> [String: String] {
        var map: [String: String] = [:]
        let pattern = #"(?is)<a\b[^>]*href\s*=\s*"([^"]+)"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return map }
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = ns.substring(with: match.range(at: 1))
            let rawTitle = ns.substring(with: match.range(at: 2))
            let title = clean(rawTitle)
            guard !title.isEmpty else { continue }
            map[normalize(href)] = title
        }
        return map
    }

    static func parseNCX(_ xml: String) -> [String: String] {
        var map: [String: String] = [:]
        let pointPattern = #"(?is)<navPoint\b.*?</navPoint>"#
        let textPattern = #"(?is)<text[^>]*>(.*?)</text>"#
        let srcPattern = #"(?is)<content[^>]*src\s*=\s*"([^"]+)""#

        guard let pointRegex = try? NSRegularExpression(pattern: pointPattern),
              let textRegex = try? NSRegularExpression(pattern: textPattern),
              let srcRegex = try? NSRegularExpression(pattern: srcPattern) else { return map }

        let ns = xml as NSString
        for point in pointRegex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let block = ns.substring(with: point.range)
            let blockNS = block as NSString
            let blockRange = NSRange(location: 0, length: blockNS.length)

            guard let textMatch = textRegex.firstMatch(in: block, range: blockRange),
                  let srcMatch = srcRegex.firstMatch(in: block, range: blockRange) else { continue }

            let title = clean(blockNS.substring(with: textMatch.range(at: 1)))
            let src = blockNS.substring(with: srcMatch.range(at: 1))
            guard !title.isEmpty, !src.isEmpty else { continue }
            map[normalize(src)] = title
        }
        return map
    }

    /// 去掉 #fragment 与解码百分号
    static func normalize(_ href: String) -> String {
        var value = href
        if let hash = value.firstIndex(of: "#") {
            value = String(value[..<hash])
        }
        return value.removingPercentEncoding ?? value
    }

    private static func clean(_ html: String) -> String {
        HTMLText.plain(from: html)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
