import Foundation

/// 解析 EPUB 的 package document(OPF):manifest + spine + 元数据 + 封面/目录指针。
final class OPFScanner: NSObject, XMLParserDelegate {
    struct Item {
        var id: String
        var href: String
        var mediaType: String
        var properties: String

        var isNavigation: Bool { properties.contains("nav") }
        var isCoverImage: Bool { properties.contains("cover-image") }
    }

    struct Package {
        var manifest: [String: Item] = [:]
        var spine: [String] = []
        var title: String = ""
        var author: String = ""
        var coverID: String?
        var tocID: String?
    }

    private var package = Package()
    private var currentText = ""

    static func parse(_ data: Data) -> Package {
        let scanner = OPFScanner()
        let parser = XMLParser(data: data)
        parser.delegate = scanner
        parser.shouldProcessNamespaces = false
        parser.parse()
        return scanner.package
    }

    /// 从 META-INF/container.xml 取 OPF 路径
    static func rootFilePath(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"full-path\s*=\s*"([^"]+)""#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[valueRange])
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        switch elementName {
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                let item = Item(id: id,
                                href: href,
                                mediaType: attributeDict["media-type"] ?? "",
                                properties: attributeDict["properties"] ?? "")
                package.manifest[id] = item
            }
        case "itemref":
            if let idref = attributeDict["idref"] {
                package.spine.append(idref)
            }
        case "spine":
            package.tocID = attributeDict["toc"]
        case "meta":
            if attributeDict["name"] == "cover", package.coverID == nil {
                package.coverID = attributeDict["content"]
            }
        default:
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title", "dc:title":
            if package.title.isEmpty, !value.isEmpty { package.title = value }
        case "creator", "dc:creator":
            if package.author.isEmpty, !value.isEmpty { package.author = value }
        default:
            break
        }
        currentText = ""
    }
}
