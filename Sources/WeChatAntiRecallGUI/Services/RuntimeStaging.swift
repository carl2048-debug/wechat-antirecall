import Foundation
import CryptoKit

enum RuntimeStaging {
    /// Run as the GUI's user, before asking the privileged CLI to inject. Root's
    /// filesystem access does not grant the sandboxed target access to our bundle.
    static func stage(source: URL, appPath: String) throws -> URL {
        let bundle = Bundle(url: URL(fileURLWithPath: appPath))
        guard let identifier = bundle?.bundleIdentifier,
              identifier == "com.tencent.xinWeChat" ||
                (identifier.hasPrefix("com.tencent.xinWeChat.antirecall.clone") && bundle?.object(forInfoDictionaryKey: "WeChatAntiRecallClone") as? Bool == true) else {
            throw NSError(domain: "RuntimeStaging", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法确定当前微信的沙箱容器，请选择原版微信。"
            ])
        }
        let manager = FileManager.default
        if identifier != "com.tencent.xinWeChat" {
            // Project-created clones are re-signed without the source's sandbox
            // entitlement. Their cache belongs to the normal user home.
            let cache = manager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/WeChatAntiRecallRuntime/\(identifier)", isDirectory: true)
            try manager.createDirectory(at: cache, withIntermediateDirectories: true)
            return try copy(source: source, cache: cache)
        }
        let container = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(identifier)/Data", isDirectory: true)
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: container.path, isDirectory: &directory), directory.boolValue else {
            throw NSError(domain: "RuntimeStaging", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "尚未找到微信数据容器，请先正常打开一次微信。"
            ])
        }
        let cache = container.appendingPathComponent("Library/Caches/WeChatAntiRecallRuntime", isDirectory: true)
        try manager.createDirectory(at: cache, withIntermediateDirectories: true)
        return try copy(source: source, cache: cache)
    }

    private static func copy(source: URL, cache: URL) throws -> URL {
        let manager = FileManager.default
        // Never overwrite/unlink a dylib that a running process may still map.
        // Copies are kept in the target's cache until its normal cache cleanup.
        let sourceData = try Data(contentsOf: source)
        let digest = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
        let destination = cache.appendingPathComponent("runtime-\(digest).dylib")
        if manager.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == sourceData else {
                throw NSError(domain: "RuntimeStaging", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "缓存的插件内容异常，请清理插件缓存后重试。"])
            }
            return destination
        }
        try manager.copyItem(at: source, to: destination)
        return destination
    }
}
