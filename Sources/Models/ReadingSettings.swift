import SwiftUI
import UIKit

// MARK: - 主题

enum ReaderTheme: String, CaseIterable, Identifiable {
    case paper      // 纸白
    case cream      // 米黄
    case green      // 护眼
    case gray       // 灰调
    case dark       // 夜间
    case black      // 纯黑(OLED)
    case system     // 跟随系统

    var id: String { rawValue }

    var name: String {
        switch self {
        case .paper: return "纸白"
        case .cream: return "米黄"
        case .green: return "护眼"
        case .gray: return "灰调"
        case .dark: return "夜间"
        case .black: return "纯黑"
        case .system: return "跟随系统"
        }
    }

    var background: Color { Color(uiColor: uiBackground) }

    var uiBackground: UIColor {
        switch self {
        case .paper: return UIColor(red: 0.99, green: 0.99, blue: 0.975, alpha: 1)
        case .cream: return UIColor(red: 0.96, green: 0.93, blue: 0.85, alpha: 1)
        case .green: return UIColor(red: 0.80, green: 0.88, blue: 0.80, alpha: 1)
        case .gray: return UIColor(red: 0.93, green: 0.93, blue: 0.92, alpha: 1)
        case .dark: return UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        case .black: return UIColor.black
        case .system:
            return UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
                    : UIColor(red: 0.99, green: 0.99, blue: 0.975, alpha: 1)
            }
        }
    }

    var textColor: Color { Color(uiColor: uiTextColor) }

    var uiTextColor: UIColor {
        switch self {
        case .paper, .cream, .green, .gray:
            return UIColor(red: 0.13, green: 0.12, blue: 0.11, alpha: 1)
        case .dark:
            return UIColor(red: 0.80, green: 0.80, blue: 0.82, alpha: 1)
        case .black:
            return UIColor(red: 0.70, green: 0.70, blue: 0.72, alpha: 1)
        case .system:
            return UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0.80, green: 0.80, blue: 0.82, alpha: 1)
                    : UIColor(red: 0.13, green: 0.12, blue: 0.11, alpha: 1)
            }
        }
    }

    var secondaryColor: Color {
        switch self {
        case .dark, .black: return Color(white: 0.62)
        default: return Color(uiColor: .secondaryLabel)
        }
    }

    /// 朗读高亮色:跟随主题的暖色块,避免刺眼的纯黄
    var highlightColor: UIColor {
        switch self {
        case .paper:
            return UIColor(red: 0.965, green: 0.918, blue: 0.804, alpha: 1)
        case .cream:
            return UIColor(red: 0.941, green: 0.878, blue: 0.725, alpha: 1)
        case .green:
            return UIColor(red: 0.882, green: 0.929, blue: 0.800, alpha: 1)
        case .gray:
            return UIColor(red: 0.902, green: 0.890, blue: 0.855, alpha: 1)
        case .dark:
            return UIColor(white: 0.98, alpha: 0.16)
        case .black:
            return UIColor(white: 0.98, alpha: 0.13)
        case .system:
            return UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(white: 0.98, alpha: 0.16)
                    : UIColor(red: 0.965, green: 0.918, blue: 0.804, alpha: 1)
            }
        }
    }

    var prefersLightStatusBar: Bool {
        switch self {
        case .dark, .black: return true
        case .system: return UITraitCollection.current.userInterfaceStyle == .dark
        default: return false
        }
    }
}

// MARK: - 字体

enum ReaderFontFamily: String, CaseIterable, Identifiable {
    case system
    case songti
    case kaiti
    case heiti
    case mono

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: return "系统"
        case .songti: return "宋体"
        case .kaiti: return "楷体"
        case .heiti: return "黑体"
        case .mono: return "等宽"
        }
    }

    private var candidates: [String] {
        switch self {
        case .songti: return ["Songti SC", "STSongti-SC-Regular", "Times New Roman"]
        case .kaiti: return ["Kaiti SC", "STKaiti-SC-Regular", "STKaiti"]
        case .heiti: return ["PingFang SC", "Heiti SC", "STHeitiSC-Light"]
        default: return []
        }
    }

    func uiFont(ofSize size: CGFloat) -> UIFont {
        if self == .system { return UIFont.systemFont(ofSize: size) }
        if self == .mono { return UIFont.monospacedSystemFont(ofSize: size, weight: .regular) }
        for name in candidates where UIFont(name: name, size: size) != nil {
            return UIFont(name: name, size: size)!
        }
        return UIFont.systemFont(ofSize: size)
    }
}

// MARK: - 排版

enum ReaderTextAlignment: String, CaseIterable, Identifiable {
    case leading
    case justified

    var id: String { rawValue }

    var name: String {
        switch self {
        case .leading: return "左对齐"
        case .justified: return "两端对齐"
        }
    }

    var nsAlignment: NSTextAlignment {
        switch self {
        case .leading: return .left
        case .justified: return .justified
        }
    }
}

enum ReaderPageMode: String, CaseIterable, Identifiable {
    case slide
    case curl
    case scroll

    var id: String { rawValue }

    var name: String {
        switch self {
        case .slide: return "左右翻页"
        case .curl: return "仿真翻页"
        case .scroll: return "上下滚动"
        }
    }
}

// MARK: - 设置

@MainActor
final class ReadingSettings: ObservableObject {
    @Published var theme: ReaderTheme { didSet { write(theme.rawValue, .theme) } }
    @Published var fontSize: Double { didSet { write(fontSize, .fontSize) } }
    @Published var lineHeightMultiple: Double { didSet { write(lineHeightMultiple, .lineHeight) } }
    @Published var paragraphSpacing: Double { didSet { write(paragraphSpacing, .paragraphSpacing) } }
    @Published var firstLineIndent: Double { didSet { write(firstLineIndent, .indent) } }
    @Published var margin: Double { didSet { write(margin, .margin) } }
    @Published var fontFamily: ReaderFontFamily { didSet { write(fontFamily.rawValue, .fontFamily) } }
    @Published var alignment: ReaderTextAlignment { didSet { write(alignment.rawValue, .alignment) } }
    @Published var pageMode: ReaderPageMode { didSet { write(pageMode.rawValue, .pageMode) } }
    @Published var showHeaderFooter: Bool { didSet { write(showHeaderFooter, .showChrome) } }
    /// 朗读倍速 1.0–3.0
    @Published var speechRateMultiplier: Double { didSet { write(speechRateMultiplier, .speechRate) } }
    /// 预缓存段数 5–15
    @Published var prefetchCount: Double { didSet { write(prefetchCount, .prefetch) } }
    @Published var autoTurnPageOnSpeech: Bool { didSet { write(autoTurnPageOnSpeech, .autoTurn) } }

    private enum Key: String {
        case theme, fontSize, lineHeight, paragraphSpacing, indent, margin
        case fontFamily, alignment, pageMode, showChrome, speechRate, prefetch, autoTurn
    }

    init() {
        let defaults = UserDefaults.standard
        theme = ReaderTheme(rawValue: defaults.string(forKey: Key.theme.rawValue) ?? "") ?? .paper
        fontSize = defaults.object(forKey: Key.fontSize.rawValue) as? Double ?? 19
        lineHeightMultiple = defaults.object(forKey: Key.lineHeight.rawValue) as? Double ?? 1.55
        paragraphSpacing = defaults.object(forKey: Key.paragraphSpacing.rawValue) as? Double ?? 8
        firstLineIndent = defaults.object(forKey: Key.indent.rawValue) as? Double ?? 2
        margin = defaults.object(forKey: Key.margin.rawValue) as? Double ?? 22
        fontFamily = ReaderFontFamily(rawValue: defaults.string(forKey: Key.fontFamily.rawValue) ?? "") ?? .system
        // 默认两端对齐:中文正文左右齐平,观感比左对齐整齐
        alignment = ReaderTextAlignment(rawValue: defaults.string(forKey: Key.alignment.rawValue) ?? "") ?? .justified
        // 默认仿真翻页
        pageMode = ReaderPageMode(rawValue: defaults.string(forKey: Key.pageMode.rawValue) ?? "") ?? .curl
        showHeaderFooter = defaults.object(forKey: Key.showChrome.rawValue) as? Bool ?? true
        speechRateMultiplier = defaults.object(forKey: Key.speechRate.rawValue) as? Double ?? 1.0
        prefetchCount = defaults.object(forKey: Key.prefetch.rawValue) as? Double ?? 10
        autoTurnPageOnSpeech = defaults.object(forKey: Key.autoTurn.rawValue) as? Bool ?? true
    }

    /// 兼容旧版本存的是 AVSpeech rate(0.35–0.7)
    var normalizedMultiplier: Double {
        speechRateMultiplier < 0.95 ? max(1, speechRateMultiplier * 2.2) : speechRateMultiplier
    }

    var uiFont: UIFont {
        fontFamily.uiFont(ofSize: CGFloat(fontSize))
    }

    /// 分页与渲染共用同一份属性,保证视觉与切页完全对齐
    var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = CGFloat(lineHeightMultiple)
        paragraph.paragraphSpacing = CGFloat(paragraphSpacing)
        paragraph.firstLineHeadIndent = CGFloat(firstLineIndent) * CGFloat(fontSize)
        paragraph.alignment = alignment.nsAlignment
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.hyphenationFactor = 0

        return [
            .font: uiFont,
            .foregroundColor: theme.uiTextColor,
            .paragraphStyle: paragraph
        ]
    }

    private func write(_ value: Any, _ key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }
}
