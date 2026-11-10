import Foundation

@MainActor
final class KeywordAlertController: ObservableObject {
    struct Report: Decodable {
        struct Settings: Decodable {
            let enabled: Bool
            let keywords: [String]
        }
        let schemaVersion: Int
        let settings: Settings
        let supported: Bool
        let build: String
        let runtimeAvailable: Bool
    }

    static let maximumKeywords = 20
    static let maximumKeywordLength = 32

    @Published private(set) var enabled = false
    /// Keywords saved in WeChat's settings; the editor works on a separate draft.
    @Published private(set) var savedKeywords: [String] = []
    @Published var draftKeywords: [String] = []
    @Published private(set) var supported = false
    @Published private(set) var runtimeAvailable = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    private var revision: UInt64 = 0

    var hasUnsavedChanges: Bool { draftKeywords != savedKeywords }

    /// Adds `text` to the draft. Returns a reason when it cannot be added, nil on success.
    func addDraftKeyword(_ text: String) -> String? {
        let keyword = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return "请输入关键词。" }
        guard keyword.utf16.count <= Self.maximumKeywordLength else { return "关键词最长 \(Self.maximumKeywordLength) 个字符。" }
        // The CLI reads "--" as the start of an option, so such a keyword could not be saved.
        guard !keyword.hasPrefix("--") else { return "关键词不能以两个连字符开头。" }
        guard !keyword.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return "关键词不能包含控制字符。"
        }
        guard !draftKeywords.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) else {
            return "这个关键词已经在列表里了。"
        }
        guard draftKeywords.count < Self.maximumKeywords else { return "最多支持 \(Self.maximumKeywords) 个关键词。" }
        draftKeywords.append(keyword)
        return nil
    }

    func removeDraftKeyword(_ keyword: String) {
        draftKeywords.removeAll { $0 == keyword }
    }

    func load(appPath: String) async { await run(["get"], appPath: appPath, saving: false, successMessage: nil) }

    func saveKeywords(appPath: String) async {
        let arguments = ["set"] + draftKeywords.flatMap { ["--keyword", $0] }
        await run(arguments, appPath: appPath, saving: true,
                  successMessage: enabled ? "已保存。新关键词立即生效。" : "已保存。")
    }

    func setEnabled(_ newValue: Bool, appPath: String) async {
        var arguments = [newValue ? "on" : "off"]
        // Turning on with unsaved edits saves them first, so the switch never uses a stale list.
        if newValue { arguments += draftKeywords.flatMap { ["--keyword", $0] } }
        await run(arguments, appPath: appPath, saving: true,
                  successMessage: newValue
                    ? "已开启。新收到的文字消息命中关键词时会弹系统通知；更新运行组件后，请重新注入；普通设置保存后生效。"
                    : "已关闭关键词提醒。关键词仍然保留。")
    }

    private func run(_ arguments: [String], appPath: String, saving: Bool, successMessage: String?) async {
        revision &+= 1
        let activeRevision = revision
        busy = true
        error = nil
        message = nil
        if !saving { enabled = false; supported = false; runtimeAvailable = false }
        let result = await CLIRunner.runUser(
            BundledPaths.cli, ["keyword-alert"] + arguments + ["--app", appPath, "--json"])
        guard revision == activeRevision else { return }
        busy = false
        if result.succeeded,
           let report = try? JSONDecoder().decode(Report.self, from: Data(result.output.utf8)),
           report.schemaVersion == GUICLIProtocol.schemaVersion {
            enabled = report.settings.enabled
            savedKeywords = report.settings.keywords
            // Switching off does not send the draft, so unsaved edits must survive it.
            let keepsDraft = arguments.first == "off" && hasUnsavedChanges
            if !keepsDraft { draftKeywords = report.settings.keywords }
            supported = report.supported
            runtimeAvailable = report.runtimeAvailable
            message = successMessage
        } else if let envelope = try? JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(result.output.utf8)) {
            error = envelope.error.message
        } else {
            let failureText = (result.output + result.stderr).lowercased()
            if failureText.contains("permission") || failureText.contains("not permitted") || failureText.contains("权限") {
                error = "无法读取微信设置。请为本工具开启「完全磁盘访问权限」，退出并重新打开后重试。"
            } else {
                error = "无法读取或保存关键词提醒设置。请重新读取后重试。"
            }
        }
    }
}
