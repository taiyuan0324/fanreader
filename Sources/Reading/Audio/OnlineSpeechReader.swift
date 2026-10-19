import Foundation
import AVFoundation

/// 在线语音播放器:按片段请求音频并顺序播放,同时向前预取若干段(可配置 5–15)。
@MainActor
final class OnlineSpeechReader: NSObject, AVAudioPlayerDelegate {
    static let shared = OnlineSpeechReader()

    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?
    private var task: Task<Void, Never>?

    private(set) var isPlaying = false
    var onError: ((Error) -> Void)?
    /// 正在播放的片段文本,用于文字高亮跟随
    var onChunkText: ((String) -> Void)?

    // MARK: - 播放

    func play(sentences: [String],
              provider: TTSProvider,
              voice: String,
              rate: Double,
              prefetch: Int,
              clientRate: Double = 1.0,
              onPageFinished: @escaping () -> Void) {
        stop()
        guard !sentences.isEmpty else { return }

        let ahead = max(1, min(prefetch, 15))
        let concurrency = 3          // 同时在跑的请求数,避免把服务打爆

        task = Task { [weak self] in
            guard let self else { return }
            await self.activateSession()

            var inFlight: [Int: Task<Data, Error>] = [:]
            var nextToStart = 0

            func start(upTo slot: Int) {
                while nextToStart < sentences.count,
                      nextToStart < slot + ahead,
                      inFlight.count < concurrency {
                    let index = nextToStart
                    let text = sentences[index]
                    inFlight[index] = Task {
                        try await provider.synthesize(TTSRequest(text: text, rate: rate, voice: voice))
                    }
                    nextToStart += 1
                }
            }

            for index in sentences.indices {
                if Task.isCancelled { break }
                start(upTo: index)

                guard let request = inFlight[index] else { continue }
                let data: Data
                do {
                    data = try await request.value
                } catch {
                    if !Task.isCancelled {
                        self.onError?(error)
                    }
                    for pending in inFlight.values { pending.cancel() }
                    self.finish()
                    return
                }
                inFlight[index] = nil

                if Task.isCancelled { break }
                self.onChunkText?(sentences[index])
                await self.playAudio(data, rate: clientRate)

                if index == sentences.count - 1 {
                    onPageFinished()
                }
            }

            for pending in inFlight.values { pending.cancel() }
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

    private func playAudio(_ data: Data, rate: Double = 1.0) async {
        guard let audio = try? AVAudioPlayer(data: data) else { return }
        audio.delegate = self
        if rate > 1.01 {
            audio.enableRate = true
            audio.rate = Float(min(max(rate, 1.0), 3.0))
        }
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
