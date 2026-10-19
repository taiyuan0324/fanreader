import Foundation

enum TTSProviderKind: String, CaseIterable, Identifiable {
    case system
    case doubao
    case edgeServer
    case azure
    case openAICompatible

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: return "系统(离线)"
        case .doubao: return "豆包(自建服务)"
        case .edgeServer: return "微软语音(自建)"
        case .azure: return "Azure 语音"
        case .openAICompatible: return "OpenAI 兼容接口"
        }
    }

    var needsKey: Bool { self == .azure || self == .openAICompatible }

    /// 服务端是否支持语速参数(否则由客户端变速)
    var supportsServerRate: Bool {
        switch self {
        case .system, .doubao, .openAICompatible: return false
        case .edgeServer, .azure: return true
        }
    }

    var hint: String {
        switch self {
        case .system:
            return "使用 AVSpeechSynthesizer,无需网络与密钥"
        case .doubao:
            return "连接你自己搭建的豆包 TTS,填地址后自动拉取音色列表"
        case .edgeServer:
            return "连接你服务器上的 edge-tts 服务(/api/synthesis),由服务端处理微软最新的校验"
        case .azure:
            return "填写区域(如 eastasia)与语音(如 zh-CN-XiaoxiaoNeural)"
        case .openAICompatible:
            return "任何兼容 /audio/speech 的服务:OpenAI、硅基流动、本地 vLLM 等"
        }
    }
}

struct TTSRequest {
    let text: String
    let rate: Double      // 0.5 = 正常
    let voice: String
}

enum TTSError: LocalizedError {
    case missingKey
    case badURL
    case http(status: Int, body: String)
    case emptyAudio
    case message(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "还没有填 API Key"
        case .badURL: return "接口地址不合法"
        case .http(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "服务返回 HTTP \(status)\(trimmed.isEmpty ? "" : ":" + String(trimmed.prefix(160)))"
        case .emptyAudio: return "服务没有返回音频数据"
        case .message(let text): return text
        }
    }
}

protocol TTSProvider {
    var kind: TTSProviderKind { get }
    func synthesize(_ request: TTSRequest) async throws -> Data
}

// MARK: - Azure 语音服务

struct AzureTTSProvider: TTSProvider {
    let kind: TTSProviderKind = .azure
    let region: String
    let key: String

    func synthesize(_ request: TTSRequest) async throws -> Data {
        let trimmedRegion = region.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw TTSError.missingKey }
        guard !trimmedRegion.isEmpty,
              let url = URL(string: "https://\(trimmedRegion).tts.speech.microsoft.com/cognitiveservices/v1") else {
            throw TTSError.badURL
        }

        let voice = request.voice.isEmpty ? "zh-CN-XiaoxiaoNeural" : request.voice
        let ratePercent = Int(((request.rate - 1.0) * 100).rounded())
        let rateString = ratePercent >= 0 ? "+\(ratePercent)%" : "\(ratePercent)%"

        let escaped = request.text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        let ssml = """
        <speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'>\
        <voice name='\(voice)'><prosody rate='\(rateString)'>\(escaped)</prosody></voice></speak>
        """

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(trimmedKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        urlRequest.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("audio-24khz-48kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        urlRequest.setValue("FanReader", forHTTPHeaderField: "User-Agent")
        urlRequest.httpBody = ssml.data(using: .utf8)
        urlRequest.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw TTSError.message("响应异常")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TTSError.http(status: http.statusCode,
                                body: String(data: data, encoding: .utf8) ?? "")
        }
        guard !data.isEmpty else { throw TTSError.emptyAudio }
        return data
    }
}

// MARK: - OpenAI 兼容接口(/v1/audio/speech)

struct OpenAICompatTTSProvider: TTSProvider {
    let kind: TTSProviderKind = .openAICompatible
    let baseURL: String
    let key: String
    let model: String

    func synthesize(_ request: TTSRequest) async throws -> Data {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw TTSError.missingKey }

        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var endpoint = base.hasSuffix("/") ? String(base.dropLast()) : base
        if !endpoint.hasSuffix("/audio/speech") {
            endpoint += "/audio/speech"
        }
        guard let url = URL(string: endpoint) else { throw TTSError.badURL }

        let body: [String: Any] = [
            "model": model.isEmpty ? "tts-1" : model,
            "input": request.text,
            "voice": request.voice.isEmpty ? "alloy" : request.voice,
            "response_format": "mp3"
        ]

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw TTSError.message("响应异常")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TTSError.http(status: http.statusCode,
                                body: String(data: data, encoding: .utf8) ?? "")
        }
        guard !data.isEmpty else { throw TTSError.emptyAudio }
        return data
    }
}
