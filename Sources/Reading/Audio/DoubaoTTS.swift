import Foundation

/// 自建豆包 TTS 服务(地址由用户在设置里填写,不写入代码)。
/// 接口:GET /status、GET /speakers、POST /tts {text, speaker} → audio/aac
struct DoubaoTTSProvider: TTSProvider {
    let kind: TTSProviderKind = .doubao
    let baseURL: String
    let speaker: String

    func synthesize(_ request: TTSRequest) async throws -> Data {
        guard let url = Self.endpoint(baseURL: baseURL, path: "/tts") else { throw TTSError.badURL }

        var body: [String: Any] = ["text": request.text]
        if !speaker.isEmpty { body["speaker"] = speaker }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        // 浏览器端合成需要排队,给足时间
        urlRequest.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw TTSError.message("响应异常")
        }

        // 服务端可能把豆包降级成微软(edge),这里记录下来供界面提示
        let served = http.value(forHTTPHeaderField: "X-TTS-Engine") ?? "doubao"
        TTSEngineTrace.shared.set(served)

        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw TTSError.http(status: http.statusCode, body: text)
        }
        guard !data.isEmpty else { throw TTSError.emptyAudio }
        return data
    }

    // MARK: - 服务探测

    struct Status {
        let ready: Bool
        let speakers: Int
        let engine: String
    }

    static func status(baseURL: String) async throws -> Status {
        guard let url = endpoint(baseURL: baseURL, path: "/status") else { throw TTSError.badURL }
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TTSError.message("服务未响应,请确认地址与端口")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TTSError.message("返回格式不对,可能不是豆包 TTS 服务")
        }
        return Status(ready: json["ready"] as? Bool ?? false,
                      speakers: json["speakers"] as? Int ?? 0,
                      engine: json["engine"] as? String ?? "-")
    }

    static func speakers(baseURL: String) async throws -> [String] {
        guard let url = endpoint(baseURL: baseURL, path: "/speakers") else { throw TTSError.badURL }
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TTSError.message("取音色列表失败")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["speakers"] as? [String] else {
            throw TTSError.message("音色列表格式不对")
        }
        return list
    }

    private static func endpoint(baseURL: String, path: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        if !base.hasPrefix("http://") && !base.hasPrefix("https://") {
            base = "http://" + base
        }
        return URL(string: base + path)
    }
}

/// 该服务靠浏览器端合成,单次请求约 2–4 秒,所以按较长片段合并,减少往返次数。
enum SpeechChunking {
    static func chunks(_ text: String, providerKind: TTSProviderKind) -> [String] {
        switch providerKind {
        case .doubao:
            // 浏览器端合成慢,段落切小一点可以更快出第一段声音
            return merge(SentenceSplitter.split(text, maxLength: 110), limit: 140)
        case .edgeServer:
            // 段越短高亮越贴合,服务端有预缓存兜底
            return SentenceSplitter.split(text, maxLength: 110)
        default:
            return SentenceSplitter.split(text, maxLength: 90)
        }
    }

    private static func merge(_ sentences: [String], limit: Int) -> [String] {
        var result: [String] = []
        var buffer = ""

        for sentence in sentences {
            if buffer.isEmpty {
                buffer = sentence
            } else if buffer.count + sentence.count + 1 <= limit {
                buffer += " " + sentence
            } else {
                result.append(buffer)
                buffer = sentence
            }
        }
        if !buffer.isEmpty { result.append(buffer) }
        return result
    }
}
