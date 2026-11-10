import Foundation
import WeChatRuntimeSession

struct NativeOptionsReport: Encodable {
    let silent: Bool
    let blockUpdates: Bool
    let active: Bool
    let canBlockUpdates: Bool
    let contentCache: Bool
}

func runtimeComponentAvailable(info: AppInfo, marker: String) -> Bool {
    if let session = NativeRuntimeSession.read(appURL: info.appURL), session.supports(marker) { return true }
    if NativeRuntimeSession.supportedBuilds.contains(info.buildVersion) { return false }
    let path = info.appURL.appendingPathComponent(RuntimeTipInstaller.destinationDylibPath)
    return (try? Data(contentsOf: path, options: .mappedIfSafe))?.range(of: Data(marker.utf8)) != nil
}

func nativeOptions(app: AppInfo, arguments: [String]) throws -> NativeOptionsReport {
    guard NativeRuntimeSession.supportedBuilds.contains(app.buildVersion) else { throw ToolError.usage("原生选项支持构建 268602、270353") }
    let store = RecallTipPreferenceStore(domain: app.bundleIdentifier)
    let key = "WeChatAntiRecall_NativeOptions"
    var value = (try store.preferenceValue(forKey: key)) as? [String: Bool] ?? [:]
    let session = NativeRuntimeSession.read(appURL: app.appURL)
    var changed = false
    var index = 0
    while index < arguments.count {
        let flag = arguments[index]
        if flag == "get" || flag == "--json" { index += 1; continue }
        guard ["--silent", "--block-update"].contains(flag), index + 1 < arguments.count,
              ["on", "off"].contains(arguments[index + 1]) else { throw ToolError.usage("native-options 接受 get、--silent on/off、--block-update on/off") }
        let enabled = arguments[index + 1] == "on"
        if flag == "--block-update" && enabled && session?.supports("WeChatAntiRecallBlockUpdates:1") != true {
            throw ToolError.usage("请先注入包含屏蔽更新功能的运行组件；若已注入，当前微信的更新方法未通过校验。")
        }
        value[flag == "--silent" ? "silent" : "blockUpdates"] = enabled
        changed = true
        index += 2
    }
    if changed { try store.setPreferenceValue(value, forKey: key) }
    return NativeOptionsReport(silent: value["silent"] ?? false, blockUpdates: value["blockUpdates"] ?? false,
        active: session != nil, canBlockUpdates: session?.supports("WeChatAntiRecallBlockUpdates:1") == true,
        contentCache: session?.contentCache == true)
}
