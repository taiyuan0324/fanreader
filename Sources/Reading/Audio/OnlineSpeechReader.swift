import Foundation
import AVFoundation

/// 已合成好的音频块
private enum BufferedAudio: @unchecked Sendable {
    case data(Data)
    case failed(String)
}

/// 按顺序发号的计数器(生产端取任务用)
private actor ChunkCounter {
    private var next = 0
    private let total: Int
    private var stopped = false

    init(total: Int) { self.total = total }

    func take() -> Int? {
        guard !stopped, next < total else { return nil }
        let value = next
        next += 1
        return value
    }

    func stop() { stopped = true }
}

/// 已完成音频的缓冲区
private actor AudioBuffer {
    private var items: [Int: BufferedAudio] = [:]
    private var waiters: [Int: CheckedContinuation<BufferedAudio, Never>] = [:]

    func put(_ index: Int, _ value: BufferedAudio) {
        if let waiter = waiters.removeValue(forKey: index) {
            waiter.resume(returning: value)
        } else {
            items[index] = value
        }
    }

    func take(_ index: Int) async -> BufferedAudio {
        if let value = items.removeValue(forKey: index) { return value }
        return await withCheckedContinuation { continuation in
            waiters[index] = continuation
        }
    }

    /// 已就绪但还没被消费的段数(用于限制预取深度)
    var pending: Int { items.count }

    func flush() {
        for (_, waiter) in waiters {
            waiter.resume(returning: .failed("cancelled"))
        }
        waiters.removeAll()
        items.removeAll()
    }
}

/// 在线语音播放器:生产端低并发预取,消费端顺序播放。
/// 关键点:播放当前段的同时,后面的段已经在合成,所以段与段之间不再空等。
@MainActor
final class OnlineSpeechReader: NSObject, AVAudioPlayerDelegate {
    static let shared = OnlineSpeechReader()

    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?
    private var task: Task<Void, Never>?
    private var buffer: AudioBuffer?

    private(set) var isPlaying = false
    var onError: ((Error) -> Void)?

    func play(chunks: [SpeechChunk],
              provider: TTSProvider,
              voice: String,
              rate: Double,
              prefetch: Int,
              clientRate: Double = 1.0,
              concurrency: Int = 3,
              onChunk: @escaping (Int, SpeechChunk) -> Void,
              onFinished: @escaping () -> Void) {
        stop()
        guard !chunks.isEmpty else { return }

        let ahead = max(1, min(prefetch, 15))
        let parallel = max(1, min(concurrency, 3))
        let audioBuffer = AudioBuffer()
        let counter = ChunkCounter(total: chunks.count)
        buffer = audioBuffer

        task = Task { [weak self] in
            guard let self else { return }
            await self.activateSession()

            // 生产端:最多 parallel 个请求同时在飞,同时受"最多提前 ahead 段"限制
            let producer = Task {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<parallel {
                        group.addTask {
                            while !Task.isCancelled, let index = await counter.take() {
                                // 预取深度上限:避免一口气把整章都合成占内存
                                while !Task.isCancelled, await audioBuffer.pending >= ahead {
                                    try? await Task.sleep(nanoseconds: 120_000_000)
                                }
                                if Task.isCancelled { break }
                                let chunk = chunks[index]
                                do {
                                    let data = try await provider.synthesize(
                                        TTSRequest(text: chunk.text, rate: rate, voice: voice))
                                    await audioBuffer.put(index, .data(data))
                                } catch {
                                    await audioBuffer.put(index, .failed(error.localizedDescription))
                                    await counter.stop()
                                }
                            }
                        }
                    }
                }
            }

            // 消费端:顺序取音频并播放
            for index in chunks.indices {
                if Task.isCancelled { break }
                let result = await audioBuffer.take(index)
                if Task.isCancelled { break }

                switch result {
                case .data(let data):
                    onChunk(index, chunks[index])
                    await self.playAudio(data, rate: clientRate)
                case .failed(let message):
                    producer.cancel()
                    await counter.stop()
                    await audioBuffer.flush()
                    if !Task.isCancelled {
                        self.onError?(TTSError.message(message))
                    }
                    self.finish()
                    return
                }
            }

            producer.cancel()
            await counter.stop()
            await audioBuffer.flush()
            self.buffer = nil

            // 被 stop() 打断时不能回调,否则调用方会误判"整章读完"
            let completed = !Task.isCancelled
            self.finish()
            if completed {
                onFinished()
            }
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
        if let buffer {
            Task { await buffer.flush() }
        }
        buffer = nil
        player?.stop()
        player = nil
        isPlaying = false
        continuation?.resume()
        continuation = nil
    }

    // MARK: - 内部

    private func activateSession() async {
        let session = AVAudioSession.sharedInstance()
        // 听书独占音频,不去压低/混合其它 App 的声音
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
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
