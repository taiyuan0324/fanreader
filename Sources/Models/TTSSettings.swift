import Foundation

@MainActor
final class TTSSettings: ObservableObject {
    @Published var kind: TTSProviderKind { didSet { defaults.set(kind.rawValue, forKey: "tts.kind") } }
    @Published var systemVoice: String { didSet { defaults.set(systemVoice, forKey: "tts.system.voice") } }
    @Published var doubaoBaseURL: String { didSet { defaults.set(doubaoBaseURL, forKey: "tts.doubao.base") } }
    @Published var doubaoSpeaker: String { didSet { defaults.set(doubaoSpeaker, forKey: "tts.doubao.speaker") } }
    @Published var doubaoSpeakers: [String] = []
    @Published var doubaoStatus: String = "未检测"
    @Published var edgeVoice: String { didSet { defaults.set(edgeVoice, forKey: "tts.edge.voice") } }
    @Published var azureRegion: String { didSet { defaults.set(azureRegion, forKey: "tts.azure.region") } }
    @Published var azureVoice: String { didSet { defaults.set(azureVoice, forKey: "tts.azure.voice") } }
    @Published var openAIBaseURL: String { didSet { defaults.set(openAIBaseURL, forKey: "tts.openai.base") } }
    @Published var openAIModel: String { didSet { defaults.set(openAIModel, forKey: "tts.openai.model") } }
    @Published var openAIVoice: String { didSet { defaults.set(openAIVoice, forKey: "tts.openai.voice") } }

    /// 密钥只在 Keychain 里,内存中保留一份用于编辑
    @Published var azureKey: String {
        didSet { Keychain.set(azureKey, for: Self.azureKeyKey) }
    }
    @Published var openAIKey: String {
        didSet { Keychain.set(openAIKey, for: Self.openAIKeyKey) }
    }

    @Published private(set) var lastError: String?

    private static let azureKeyKey = "tts.azure.key"
    private static let openAIKeyKey = "tts.openai.key"

    private let defaults = UserDefaults.standard

    init() {
        kind = TTSProviderKind(rawValue: defaults.string(forKey: "tts.kind") ?? "") ?? .system
        systemVoice = defaults.string(forKey: "tts.system.voice") ?? ""
        doubaoBaseURL = defaults.string(forKey: "tts.doubao.base") ?? ""
        doubaoSpeaker = defaults.string(forKey: "tts.doubao.speaker") ?? "温柔桃子"
        edgeVoice = defaults.string(forKey: "tts.edge.voice") ?? "zh-CN-XiaoxiaoNeural"
        azureRegion = defaults.string(forKey: "tts.azure.region") ?? "eastasia"
        azureVoice = defaults.string(forKey: "tts.azure.voice") ?? "zh-CN-XiaoxiaoNeural"
        openAIBaseURL = defaults.string(forKey: "tts.openai.base") ?? "https://api.openai.com/v1"
        openAIModel = defaults.string(forKey: "tts.openai.model") ?? "tts-1"
        openAIVoice = defaults.string(forKey: "tts.openai.voice") ?? "alloy"
        azureKey = Keychain.get(Self.azureKeyKey)
        openAIKey = Keychain.get(Self.openAIKeyKey)
    }

    /// 当前可用的在线引擎;未配置返回 nil,调用方回退到系统朗读
    var provider: TTSProvider? {
        switch kind {
        case .system:
            return nil
        case .doubao:
            guard !doubaoBaseURL.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return DoubaoTTSProvider(baseURL: doubaoBaseURL, speaker: doubaoSpeaker)
        case .edge:
            return EdgeTTSProvider()
        case .azure:
            guard !azureKey.isEmpty, !azureRegion.isEmpty else { return nil }
            return AzureTTSProvider(region: azureRegion, key: azureKey)
        case .openAICompatible:
            guard !openAIKey.isEmpty, !openAIBaseURL.isEmpty else { return nil }
            return OpenAICompatTTSProvider(baseURL: openAIBaseURL,
                                           key: openAIKey,
                                           model: openAIModel)
        }
    }

    var voice: String {
        switch kind {
        case .system: return systemVoice
        case .doubao: return doubaoSpeaker
        case .edge: return edgeVoice
        case .azure: return azureVoice
        case .openAICompatible: return openAIVoice
        }
    }

    var isConfigured: Bool {
        switch kind {
        case .system, .edge: return true
        case .doubao: return !doubaoBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
        case .azure: return !azureKey.isEmpty && !azureRegion.isEmpty
        case .openAICompatible: return !openAIKey.isEmpty && !openAIBaseURL.isEmpty
        }
    }

    /// 探测自建豆包服务(状态 + 音色列表)
    func probeDoubao() async {
        do {
            let status = try await DoubaoTTSProvider.status(baseURL: doubaoBaseURL)
            doubaoStatus = status.ready
                ? "在线 · \(status.speakers) 个音色 · \(status.engine)"
                : "服务在线但浏览器未就绪(可能还在登录豆包)"
            let list = try await DoubaoTTSProvider.speakers(baseURL: doubaoBaseURL)
            doubaoSpeakers = list
            if !list.contains(doubaoSpeaker), let first = list.first {
                doubaoSpeaker = first
            }
            clearError()
        } catch {
            doubaoStatus = "连接失败"
            report(error)
        }
    }

    func report(_ error: Error) {
        lastError = error.localizedDescription
    }

    func clearError() {
        lastError = nil
    }

    /// 设置页的试听
    func test(text: String = "这是一段试听,用来确认语音服务配置正确。") async {
        guard let provider else {
            report(TTSError.missingKey)
            return
        }
        do {
            let data = try await provider.synthesize(TTSRequest(text: text, rate: 0.5, voice: voice))
            await OnlineSpeechReader.shared.playOnce(data)
        } catch {
            report(error)
        }
    }
}
