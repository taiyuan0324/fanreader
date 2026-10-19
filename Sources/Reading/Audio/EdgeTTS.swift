import Foundation
import CryptoKit
import Security

/// Edge 朗读服务(微软)的语音合成。无需 Key、无需登录,音色接近豆包等商业音色。
/// 协议细节参考开源实现 edge-tts(rany2/edge-tts, 12.3k★)整理,此处为独立实现。
/// 注意:这是对微软 Edge「大声朗读」在线服务的非官方调用,可能随时调整;
/// 商业分发前请自行确认服务条款。
struct EdgeTTSProvider: TTSProvider {
    let kind: TTSProviderKind = .edge

    private static let trustedToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let chromiumVersion = "143.0.3650.75"
    private static let winEpoch: Double = 11_644_473_600   // 1601-01-01 到 1970 的秒数

    /// 中文音色目录(可自行换成任意 Edge 音色 id)
    static let chineseVoices: [(id: String, name: String)] = [
        ("zh-CN-XiaoxiaoNeural", "晓晓 · 女声(自然)"),
        ("zh-CN-XiaoyiNeural", "晓伊 · 女声(活泼)"),
        ("zh-CN-YunxiNeural", "云希 · 男声(年轻)"),
        ("zh-CN-YunjianNeural", "云健 · 男声(浑厚)"),
        ("zh-CN-YunyangNeural", "云扬 · 男声(播报)"),
        ("zh-CN-YunxiaNeural", "云夏 · 男童"),
        ("zh-CN-liaoning-XiaobeiNeural", "小北 · 东北女声"),
        ("zh-CN-shaanxi-XiaoniNeural", "小妮 · 陕西女声"),
        ("zh-HK-HiuMaanNeural", "曉曼 · 粤语女声"),
        ("zh-TW-HsiaoChenNeural", "曉臻 · 台湾女声")
    ]

    func synthesize(_ request: TTSRequest) async throws -> Data {
        let voice = request.voice.isEmpty ? "zh-CN-XiaoxiaoNeural" : request.voice
        guard var components = URLComponents(string: "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1") else {
            throw TTSError.badURL
        }
        let connectionId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        components.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: Self.trustedToken),
            URLQueryItem(name: "ConnectionId", value: connectionId),
            URLQueryItem(name: "Sec-MS-GEC", value: Self.secMsGec()),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: "2-\(Self.chromiumVersion)")
        ]
        guard let url = components.url else { throw TTSError.badURL }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Pragma")
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        urlRequest.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
                            forHTTPHeaderField: "Origin")
        urlRequest.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                                + "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 "
                                + "Edg/143.0.0.0",
                            forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("muid=\(Self.muid());", forHTTPHeaderField: "Cookie")

        let session = URLSession(configuration: .default)
        let socket = session.webSocketTask(with: urlRequest)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        // 1) 配置帧
        let timestamp = Self.rfc1123(Date())
        let config = """
        X-Timestamp:\(timestamp)\r
        Content-Type:application/json; charset=utf-8\r
        Path:speech.config\r
        \r
        {"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}
        """
        do {
            try await socket.send(.string(config))
        } catch {
            throw Self.map(error)
        }

        // 2) SSML 帧
        let ratePercent = Int((request.rate - 0.5) * 100)
        let rateString = ratePercent >= 0 ? "+\(ratePercent)%" : "\(ratePercent)%"
        let escaped = request.text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")

        let requestId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let ssml = """
        X-RequestId:\(requestId)\r
        Content-Type:application/ssml+xml\r
        X-Timestamp:\(timestamp)Z\r
        Path:ssml\r
        \r
        <speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'>\
        <voice name='\(voice)'><prosody pitch='+0Hz' rate='\(rateString)' volume='+0%'>\
        \(escaped)</prosody></voice></speak>
        """
        do {
            try await socket.send(.string(ssml))
        } catch {
            throw Self.map(error)
        }

        // 3) 收音频
        var audio = Data()
        var finished = false

        while !finished, audio.count < 8 * 1024 * 1024 {
            try Task.checkCancellation()
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                throw Self.map(error)
            }
            switch message {
            case .string(let text):
                if text.contains("Path:turn.end") { finished = true }
            case .data(let data):
                if let payload = Self.extractAudio(from: data) {
                    audio.append(payload)
                }
            @unknown default:
                break
            }
        }

        guard !audio.isEmpty else { throw TTSError.emptyAudio }
        return audio
    }

    // MARK: - 协议工具

    /// 二进制帧:2 字节头长度 + 头文本 + 音频
    private static func extractAudio(from data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let headerLength = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
        guard data.count > 2 + headerLength else { return nil }
        let headerStart = data.startIndex + 2
        let header = String(decoding: data[headerStart..<(headerStart + headerLength)], as: UTF8.self)
        guard header.contains("Path:audio") else { return nil }
        return data[(headerStart + headerLength)...]
    }

    /// Sec-MS-GEC:1601 纪元 100ns 计数(按 5 分钟取整)+ 信任令牌 的 SHA256
    private static func secMsGec() -> String {
        var ticks = Date().timeIntervalSince1970 + winEpoch
        ticks -= ticks.truncatingRemainder(dividingBy: 300)
        let hundredNanoseconds = UInt64(ticks * 10_000_000)
        let raw = "\(hundredNanoseconds)\(trustedToken)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    private static func muid() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// 把底层网络错误翻译成用户能行动的提示
    private static func map(_ error: Error) -> Error {
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .badServerResponse, .userAuthenticationRequired:
            return TTSError.message("Edge 拒绝握手(403)。微软已把 token 升级为 v2 校验,当前算法只能生成 v1。\n改用「系统(离线)」并下载增强音色,或自建 edge-tts 服务后用 OpenAI 兼容接口。")
        case .notConnectedToInternet, .networkConnectionLost:
            return TTSError.message("网络不可用,在线语音需要联网。")
        case .timedOut:
            return TTSError.message("请求超时,稍后重试或改用系统语音。")
        default:
            return TTSError.message("Edge 语音请求失败:\(urlError.localizedDescription)")
        }
    }

    private static func rfc1123(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: date)
    }
}
