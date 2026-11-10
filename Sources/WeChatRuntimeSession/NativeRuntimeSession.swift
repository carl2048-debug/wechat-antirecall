import Foundation
import WeChatNativeInjector

public struct NativeRuntimeSession: Decodable {
    public static let supportedBuilds: Set<String> = ["268602", "270353"]
    public let pid: Int32
    public let startToken: UInt64
    public let build: String
    public let executable: String
    public let components: [String]
    public let contentCache: Bool

    public static func read(appURL: URL) -> NativeRuntimeSession? {
        guard let bundle = Bundle(url: appURL), let domain = bundle.bundleIdentifier,
              domain == "com.tencent.xinWeChat" || (domain.hasPrefix("com.tencent.xinWeChat.antirecall.clone") && bundle.object(forInfoDictionaryKey: "WeChatAntiRecallClone") as? Bool == true),
              let executableURL = bundle.executableURL else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let relative = "Library/Caches/WeChatAntiRecallRuntime/\(domain)/session.json"
        let path = domain == "com.tencent.xinWeChat"
            ? home.appendingPathComponent("Library/Containers/\(domain)/Data/\(relative)")
            : home.appendingPathComponent(relative)
        guard let data = try? Data(contentsOf: path),
              let session = try? JSONDecoder().decode(Self.self, from: data),
              session.build == bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              session.startToken != 0 else { return nil }
        let executable = executableURL.resolvingSymlinksInPath().path
        guard session.executable == executable,
              executable.withCString({ wechat_find_main_process($0) }) == session.pid,
              wechat_process_start_token(session.pid) == session.startToken else { return nil }
        return session
    }

    public func supports(_ marker: String) -> Bool { components.contains(marker) }
}
