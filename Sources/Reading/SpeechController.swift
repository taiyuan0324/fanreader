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

/// 朗读统一入口。
/// 关键点:整章按绝对偏移切块,当前朗读块用 NSRange 上报,
/// 视图据此做高亮与翻页跟随,不再依赖字符串匹配。
@MainActor
final class SpeechController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var activeEngine: String = ""
    @Published private(set) var progressText: String = ""
    /// 当前朗读块在章节中的绝对区间
    @Published private(set) var currentRange: NSRange?
    /// 服务端实际使用的引擎(豆包可能被降级成微软)
    @Published private(set) var servedEngine: String = ""

    var onError: ((Error) -> Void)?
    /// 整章读完(或从起点读到底)
    var onChapterFinished: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()

    // 系统语音的分块队列
    private var systemChunks: [SpeechChunk] = []
    private var systemIndex = 0
    private var systemActive = false
    private var systemVoiceID = ""
    private var systemMultiplier: Double = 1.0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - 对外

    /// 从章节的 offset 开始朗读,一直读到章节末尾
    func speakChapter(_ text: String, from offset: Int, config: SpeechConfig) {
        stop()

        let chunks = SpeechChunker.chunks(in: text as NSString,
                                          from: offset,
                                          maxLength: Self.chunkLength(for: config.providerKind))
        guard !chunks.isEmpty else { return }
        isSpeaking = true

        if let provider = config.onlineProvider {
            activeEngine = config.providerName
            // 服务端支持语速参数的交给服务端;豆包这类只能本地变速
            let localRate = config.providerKind.supportsServerRate ? 1.0 : config.multiplier

            OnlineSpeechReader.shared.onError = { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.isSpeaking = false
                    self.onError?(error)
                }
            }

            // 豆包是浏览器端逐个合成,并发一高就触发限流→服务端降级成微软
            let parallel = config.providerKind == .doubao ? 1 : 3
            let ahead = config.providerKind == .doubao ? min(config.prefetch, 3) : config.prefetch

            OnlineSpeechReader.shared.play(chunks: chunks,
                                           provider: provider,
                                           voice: config.voice,
                                           rate: config.multiplier,
                                           prefetch: ahead,
                                           clientRate: localRate,
                                           concurrency: parallel,
                                           onChunk: { [weak self] index, chunk in
                Task { @MainActor in
                    guard let self else { return }
                    self.currentRange = chunk.range
                    self.progressText = "\(index + 1)/\(chunks.count) 段"
                    if config.providerKind == .doubao {
                        self.servedEngine = TTSEngineTrace.shared.current
                    }
                }
            }, onFinished: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.isSpeaking = false
                    self.onChapterFinished?()
                }
            })
            return
        }

        systemChunks = chunks
        systemIndex = 0
        systemActive = true
        systemVoiceID = config.systemVoiceID
        systemMultiplier = config.multiplier
        activeEngine = "系统"
        speakNextSystemChunk()
    }

    func stop() {
        OnlineSpeechReader.shared.stop()
        systemActive = false
        systemChunks = []
        systemIndex = 0
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        activeEngine = ""
        progressText = ""
        currentRange = nil
        servedEngine = ""
    }

    // MARK: - 系统语音

    private func speakNextSystemChunk() {
        guard systemActive, systemIndex < systemChunks.count else {
            let finishedNormally = systemActive
            systemActive = false
            isSpeaking = false
            // 只有自然读完才通知;被 stop() 打断时不通知
            if finishedNormally {
                onChapterFinished?()
            }
            return
        }

        let chunk = systemChunks[systemIndex]
        systemIndex += 1

        currentRange = chunk.range
        progressText = "\(systemIndex)/\(systemChunks.count) 段"

        let utterance = AVSpeechUtterance(string: chunk.text)
        utterance.voice = SystemVoiceCatalog.bestVoice(identifier: systemVoiceID)
        utterance.rate = Self.avRate(forMultiplier: systemMultiplier)
        synthesizer.speak(utterance)
    }

    /// 倍速 → AVSpeechUtterance.rate(0.5 为正常,最高 1.0)
    static func avRate(forMultiplier multiplier: Double) -> Float {
        let raw = 0.5 + (max(1, min(multiplier, 3)) - 1) * 0.25
        return Float(max(0.1, min(raw, 1.0)))
    }

    /// 块长度:越小高亮越贴合,但请求次数越多
    private static func chunkLength(for kind: TTSProviderKind) -> Int {
        switch kind {
        case .doubao: return 110
        case .edgeServer: return 120
        default: return 90
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.systemActive else { return }
            self.speakNextSystemChunk()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.systemActive {
                self.systemActive = false
                self.isSpeaking = false
            }
        }
    }
}
