import SwiftUI
import AVFoundation

struct SpeechConfig {
    /// nil 表示使用系统离线朗读
    var onlineProvider: TTSProvider?
    var voice: String = ""
    var systemVoiceID: String = ""
    var providerKind: TTSProviderKind = .system
    var providerName: String = "系统"
}

/// 朗读统一入口:在线引擎优先,失败或未配置时自动回退系统语音。
@MainActor
final class SpeechController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var activeEngine: String = ""
    /// 当前朗读进度,如 "第 3/12 段"
    @Published private(set) var progressText: String = ""

    var onPageFinished: (() -> Void)?
    var onError: ((Error) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, rate: Float, config: SpeechConfig) {
        stop()

        if let provider = config.onlineProvider {
            activeEngine = config.providerName
            isSpeaking = true

            OnlineSpeechReader.shared.onError = { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.isSpeaking = false
                    self.onError?(error)
                    self.speakWithSystem(text, rate: rate, voiceID: config.systemVoiceID)
                }
            }
            OnlineSpeechReader.shared.onChunk = { [weak self] index, total in
                Task { @MainActor in
                    self?.progressText = "第 \(index)/\(total) 段"
                }
            }
            OnlineSpeechReader.shared.play(sentences: SpeechChunking.chunks(text, providerKind: config.providerKind),
                                           provider: provider,
                                           voice: config.voice,
                                           rate: Double(rate)) { [weak self] in
                Task { @MainActor in
                    self?.isSpeaking = false
                    self?.onPageFinished?()
                }
            }
            return
        }

        speakWithSystem(text, rate: rate, voiceID: config.systemVoiceID)
    }

    func stop() {
        OnlineSpeechReader.shared.stop()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        activeEngine = ""
        progressText = ""
    }

    // MARK: - 系统语音

    private func speakWithSystem(_ text: String, rate: Float, voiceID: String = "") {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SystemVoiceCatalog.bestVoice(identifier: voiceID)
        utterance.rate = max(0.3, min(0.8, rate))
        activeEngine = "系统"
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.isSpeaking, self.activeEngine == "系统" else { return }
            self.isSpeaking = false
            self.onPageFinished?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.activeEngine == "系统" { self.isSpeaking = false }
        }
    }
}
