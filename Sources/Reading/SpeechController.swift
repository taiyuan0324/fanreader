import SwiftUI
import AVFoundation

struct SpeechConfig {
    /// nil 表示使用系统离线朗读
    var onlineProvider: TTSProvider?
    var voice: String = ""
    var systemVoiceID: String = ""
    var providerKind: TTSProviderKind = .system
    var providerName: String = "系统"
    var prefetch: Int = 6
    /// 1.0 = 正常语速,3.0 = 三倍
    var multiplier: Double = 1.0
}

/// 朗读统一入口:在线引擎优先,失败或未配置时自动回退系统语音。
@MainActor
final class SpeechController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var activeEngine: String = ""
    /// 当前朗读进度,如 "第 3/12 段"
    @Published private(set) var progressText: String = ""
    /// 正在朗读的片段文本,供正文高亮跟随
    @Published private(set) var currentChunk: String = ""

    var onPageFinished: (() -> Void)?
    var onError: ((Error) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, config: SpeechConfig) {
        stop()

        if let provider = config.onlineProvider {
            activeEngine = config.providerName
            isSpeaking = true

            OnlineSpeechReader.shared.onError = { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.isSpeaking = false
                    self.onError?(error)
                    self.speakWithSystem(text, config: config)
                }
            }
            OnlineSpeechReader.shared.onChunkText = { [weak self] chunk in
                Task { @MainActor in
                    self?.currentChunk = chunk
                }
            }

            let chunks = SpeechChunking.chunks(text, providerKind: config.providerKind)
            // 服务端支持语速参数的引擎交给服务端;豆包这类只能本地变速
            let localRate = config.providerKind.supportsServerRate ? 1.0 : config.multiplier
            OnlineSpeechReader.shared.play(sentences: chunks,
                                           provider: provider,
                                           voice: config.voice,
                                           rate: config.multiplier,
                                           prefetch: config.prefetch,
                                           clientRate: localRate) { [weak self] in
                Task { @MainActor in
                    self?.isSpeaking = false
                    self?.onPageFinished?()
                }
            }
            return
        }

        speakWithSystem(text, config: config)
    }

    func stop() {
        OnlineSpeechReader.shared.stop()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        activeEngine = ""
        progressText = ""
        currentChunk = ""
    }

    // MARK: - 系统语音

    private func speakWithSystem(_ text: String, config: SpeechConfig) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SystemVoiceCatalog.bestVoice(identifier: config.systemVoiceID)
        utterance.rate = Self.avRate(forMultiplier: config.multiplier)
        activeEngine = "系统"
        currentChunk = text
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// 倍速 → AVSpeechUtterance.rate(0.5 为正常,最高 1.0)
    static func avRate(forMultiplier multiplier: Double) -> Float {
        let raw = 0.5 + (max(1, min(multiplier, 3)) - 1) * 0.25
        return Float(max(0.1, min(raw, 1.0)))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.isSpeaking, self.activeEngine == "系统" else { return }
            self.isSpeaking = false
            self.currentChunk = ""
            self.onPageFinished?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.activeEngine == "系统" {
                self.isSpeaking = false
                self.currentChunk = ""
            }
        }
    }
}
