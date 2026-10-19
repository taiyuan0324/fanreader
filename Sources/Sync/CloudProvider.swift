import Foundation

/// 网盘同步:先用协议占位,接入时各自实现。
/// 注意:云盘 OAuth 的 client_id 必须用自己的开发者账号申请,
/// 不要复用任何第三方应用内置的凭据。
protocol CloudProvider {
    var name: String { get }
    var isAuthorized: Bool { get }
    func authorize() async throws
    func upload(_ fileURL: URL, to remotePath: String) async throws
    func download(_ remotePath: String, to fileURL: URL) async throws
}

/// 百度网盘(xpan)骨架。官方文档:https://pan.baidu.com/union/doc
struct BaiduPanProvider: CloudProvider {
    let name = "百度网盘"
    var isAuthorized: Bool { token != nil }

    private var clientID: String? { nil }   // 自建应用后填入
    private var token: String?

    func authorize() async throws {
        guard clientID != nil else { throw CloudError.notConfigured }
        // 1. 打开 https://openapi.baidu.com/oauth/2.0/authorize?response_type=token&client_id=...&redirect_uri=oob&scope=basic,netdisk
        // 2. 回调拿到 access_token 后用 keychain 保存
        throw CloudError.manualStepRequired
    }

    func upload(_ fileURL: URL, to remotePath: String) async throws {
        throw CloudError.notConfigured
    }

    func download(_ remotePath: String, to fileURL: URL) async throws {
        throw CloudError.notConfigured
    }
}

/// 阿里云盘(adrive)骨架。官方文档:https://www.alipan.com/developer
struct AliyunDriveProvider: CloudProvider {
    let name = "阿里云盘"
    var isAuthorized: Bool { token != nil }

    private var clientID: String? { nil }   // 自建应用后填入
    private var token: String?

    func authorize() async throws {
        guard clientID != nil else { throw CloudError.notConfigured }
        // OAuth 走 authorization_code + oob,拿 token 后存 keychain
        throw CloudError.manualStepRequired
    }

    func upload(_ fileURL: URL, to remotePath: String) async throws {
        throw CloudError.notConfigured
    }

    func download(_ remotePath: String, to fileURL: URL) async throws {
        throw CloudError.notConfigured
    }
}

enum CloudError: LocalizedError {
    case notConfigured
    case manualStepRequired

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未配置云盘应用凭据"
        case .manualStepRequired: return "需要先在浏览器完成 OAuth 授权"
        }
    }
}
