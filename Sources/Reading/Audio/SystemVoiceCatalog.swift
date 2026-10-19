import Foundation
import AVFoundation

struct SystemVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let quality: Int   // 0 标准 / 1 增强 / 2 高级

    var qualityLabel: String {
        switch quality {
        case 2: return "高级"
        case 1: return "增强"
        default: return "标准"
        }
    }

    var displayName: String {
        "\(name) · \(qualityLabel)"
    }
}

/// 系统内置语音目录。iOS 的「增强/高级」中文音色音质接近商业 TTS,下载后完全离线可用。
enum SystemVoiceCatalog {
    static func chineseVoices() -> [SystemVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
            .map { voice in
                SystemVoice(id: voice.identifier,
                            name: voice.name,
                            language: voice.language,
                            quality: qualityValue(voice))
            }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                return lhs.name < rhs.name
            }
    }

    /// 自动挑选:优先已下载的高级 → 增强 → 默认中文音色
    static func bestVoice(identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, !identifier.isEmpty,
           let chosen = AVSpeechSynthesisVoice(identifier: identifier) {
            return chosen
        }
        let all = AVSpeechSynthesisVoice.speechVoices()
        let chinese = all.filter { $0.language.hasPrefix("zh") }
        if #available(iOS 16.0, *), let premium = chinese.first(where: { $0.quality == .premium }) {
            return premium
        }
        if let enhanced = chinese.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: "zh-CN") ?? chinese.first
    }

    private static func qualityValue(_ voice: AVSpeechSynthesisVoice) -> Int {
        if #available(iOS 16.0, *) {
            switch voice.quality {
            case .premium: return 2
            case .enhanced: return 1
            default: return 0
            }
        }
        return voice.quality == .enhanced ? 1 : 0
    }
}
