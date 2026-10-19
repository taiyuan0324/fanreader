import Foundation
import AVFoundation

/// 在线语音播放器:把文本按句子切片,逐句请求音频并播放。
/// 不预取(每句延迟约 200–500ms),换取实现简单、可随时中断。
@MainActor
final class OnlineSpeechReader: NSObject, AVAudioPlayerDelegate {
    static let shared = OnlineSpeechReader()

    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?
    private var task: Task<Void, Never>?

    private(set) var isPlaying = false
    var onError: ((Error) -> Void)?

    // MARK: - 播放整页

    func play(sentences: [String],
              provider: TTSProvider,
              voice: String,
              rate: Double,
              onPageFinished: @escaping () -> Void) {
        stop()
        task = Task { [weak self] in
            guard let self else { return }
            await self.activateSession()

            for (index, sentence) in sentences.enumerated() {
                if Task.isCancelled { break }
                do {
                    let data = try await provider.synthesize(TTSRequest(text: sentence,
                                                                        rate: rate,
                                                                        voice: voice))
                    if Task.isCancelled { break }
                    await self.playAudio(data)
                } catch {
                    if !Task.isCancelled {
                        self.onError?(error)
                    }
                    self.finish()
                    return
                }
                if index == sentences.count - 1 {
                    onPageFinished()
                }
            }
            self.finish()
        }
    }

    func playOnce(_ data: Data) async {
        stop()
        await activateSession()
        await playAudio(data)
    }

    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        isPlaying = false
        continuation?.resume()
        continuation = nil
    }

    // MARK: - 内部

    private func activateSession() async {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    private func playAudio(_ data: Data) async {
        guard let audio = try? AVAudioPlayer(data: data) else { return }
        audio.delegate = self
        audio.prepareToPlay()
        audio.play()
        player = audio
        isPlaying = true

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
        }
    }

    private func finish() {
        isPlaying = false
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.player = nil
            self.continuation?.resume()
            self.continuation = nil
        }
    }
}

// MARK: - 分句

enum SentenceSplitter {
    static func split(_ text: String, maxLength: Int = 90) -> [String] {
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        let terminators: Set<Character> = ["。", "!", "?", ";", "…", ".", "!", "?", ";", "\n", "”", "」", "』"]

        var sentences: [String] = []
        var buffer = ""

        for character in normalized {
            buffer.append(character)
            if terminators.contains(character), buffer.count >= 6 {
                let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                buffer = ""
            } else if buffer.count >= maxLength {
                // 长句按逗号再切一刀,避免单次请求过大
                if let lastComma = buffer.lastIndex(where: { "，,、".contains($0) }),
                   buffer.distance(from: buffer.startIndex, to: lastComma) > 20 {
                    let head = String(buffer[buffer.startIndex...lastComma])
                    let tail = String(buffer[buffer.index(after: lastComma)...])
                    sentences.append(head.trimmingCharacters(in: .whitespacesAndNewlines))
                    buffer = tail
                } else {
                    sentences.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
                    buffer = ""
                }
            }
        }

        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { sentences.append(rest) }

        return sentences.filter { !$0.isEmpty }
    }
}
