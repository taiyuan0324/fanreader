import Foundation

/// 极简 HTML → 纯文本。只处理排版需要的结构,不做完整 HTML 解析。
enum HTMLText {
    static func plain(from html: String) -> String {
        var text = html

        text = replace(text, #"(?is)<(script|style|head)[^>]*>.*?</\1>"#, with: "")
        // 段落与换行
        text = replace(text, #"(?i)<\s*br\s*/?\s*>"#, with: "\n")
        text = replace(text, #"(?i)</\s*(p|div|h[1-6]|li|tr|blockquote|section|article)\s*>"#, with: "\n")
        text = replace(text, #"(?i)<\s*(p|div|h[1-6]|li|tr|blockquote|section|article)[^>]*>"#, with: "\n")
        text = replace(text, #"(?is)<[^>]+>"#, with: "")

        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        text = replace(text, #"[ \t]+"#, with: " ")
        text = replace(text, #"\n[ ]+\n"#, with: "\n")
        text = replace(text, #"\n{3,}"#, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func heading(from html: String) -> String? {
        for pattern in [#"(?is)<h[1-3][^>]*>(.*?)</h[1-3]>"#, #"(?is)<title[^>]*>(.*?)</title>"#] {
            if let raw = firstMatch(html, pattern) {
                let cleaned = plain(from: raw)
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    // MARK: - helpers

    private static func replace(_ input: String, _ pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: template)
    }

    private static func firstMatch(_ input: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: input) else { return nil }
        return String(input[range])
    }

    private static func decodeEntities(_ input: String) -> String {
        var text = input
        let map = [
            "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&amp;": "&",
            "&quot;": "\"", "&apos;": "'", "&mdash;": "—", "&ndash;": "–",
            "&hellip;": "…", "&ldquo;": "“", "&rdquo;": "”",
            "&lsquo;": "‘", "&rsquo;": "’"
        ]
        for (entity, value) in map {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text
    }
}
