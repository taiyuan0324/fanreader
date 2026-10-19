import Foundation

/// 服务器端微软语音(edge-tts-server)。
/// 接口:GET /api/synthesis?text=&voiceName=&rate=&pitch=&volume=&token= → audio/mpeg
/// 服务端跑的是官方维护的 edge_tts 库,自带 v2 token,端上不需要再实现 DRM。
struct EdgeServerTTSProvider: TTSProvider {
    let kind: TTSProviderKind = .edgeServer
    let baseURL: String
    let token: String

    func synthesize(_ request: TTSRequest) async throws -> Data {
        // 注意:`+20%` 里的 `+` 必须编码成 %2B。
        // 服务端按 application/x-www-form-urlencoded 解析,裸 `+` 会变成空格,导致 bad rate。
        let ratePercent = Int(((request.rate - 0.5) * 100).rounded())
        var pairs: [(String, String)] = [
            ("text", request.text),
            ("voiceName", request.voice.isEmpty ? "zh-CN-XiaoxiaoNeural" : request.voice),
            ("rate", ratePercent >= 0 ? "+\(ratePercent)%" : "\(ratePercent)%"),
            ("pitch", "+0Hz"),
            ("volume", "+0%"),
            ("format", "audio-24khz-48kbitrate-mono-mp3")
        ]
        if !token.isEmpty {
            pairs.append(("token", token))
        }

        let query = pairs
            .map { "\($0.0)=\(Self.encode($0.1))" }
            .joined(separator: "&")
        guard let url = URL(string: normalizedBase + "/api/synthesis?" + query) else {
            throw TTSError.badURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 45

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw TTSError.message("响应异常")
        }
        switch http.statusCode {
        case 200..<300:
            guard !data.isEmpty else { throw TTSError.emptyAudio }
            return data
        case 401:
            throw TTSError.message("鉴权失败:请检查服务端 TOKEN")
        default:
            throw TTSError.http(status: http.statusCode,
                                body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - 服务探测

    static func voices(baseURL: String, token: String) async throws -> [String] {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasPrefix("http://") && !base.hasPrefix("https://") { base = "http://" + base }

        let suffix = token.isEmpty ? "" : "?token=\(encode(token))"
        guard let url = URL(string: base + "/api/voices" + suffix) else { throw TTSError.badURL }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw TTSError.message("响应异常") }
        guard (200..<300).contains(http.statusCode) else {
            throw http.statusCode == 401
                ? TTSError.message("鉴权失败:TOKEN 不对")
                : TTSError.http(status: http.statusCode, body: "")
        }
        guard let list = try? JSONDecoder().decode([String].self, from: data) else {
            throw TTSError.message("音色列表格式不对,确认是 edge-tts-server")
        }
        return list
    }

    /// RFC3986 严格编码:`+`、`%`、空格等一律转义
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private var normalizedBase: String {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasPrefix("http://") && !base.hasPrefix("https://") { base = "http://" + base }
        return base
    }
}

/// 音色名 → 友好中文名(服务器返回的是 ShortName)
enum EdgeVoiceNames {
    private static let table: [String: String] = [
        "zh-CN-XiaoxiaoNeural": "晓晓 · 女声(自然)",
        "zh-CN-XiaoyiNeural": "晓伊 · 女声(活泼)",
        "zh-CN-YunxiNeural": "云希 · 男声(年轻)",
        "zh-CN-YunjianNeural": "云健 · 男声(浑厚)",
        "zh-CN-YunyangNeural": "云扬 · 男声(播报)",
        "zh-CN-YunxiaNeural": "云夏 · 男童",
        "zh-CN-liaoning-XiaobeiNeural": "小北 · 东北女声",
        "zh-CN-shaanxi-XiaoniNeural": "小妮 · 陕西女声",
        "zh-HK-HiuMaanNeural": "曉曼 · 粤语女声",
        "zh-HK-WanLungNeural": "雲龍 · 粤语男声",
        "zh-TW-HsiaoChenNeural": "曉臻 · 台湾女声",
        "zh-TW-YunJheNeural": "雲哲 · 台湾男声"
    ]

    static func friendly(_ shortName: String) -> String {
        table[shortName] ?? shortName
    }
}
