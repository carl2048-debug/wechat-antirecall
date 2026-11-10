import SwiftUI

struct NativeOptionsView: View {
    @EnvironmentObject var state: AppState
    @State private var silent = false
    @State private var blockUpdates = false
    @State private var canBlockUpdates = false
    @State private var busy = false
    @State private var error: String?

    private struct Report: Decodable {
        let silent: Bool
        let blockUpdates: Bool
        let canBlockUpdates: Bool
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "当前版本的动态功能")
                Text(state.nativeRuntimeActive ? "运行组件已加载" : "请先在首页注入微信，功能随微信退出而失效。")
                    .font(.callout).foregroundStyle(.secondary)
                if state.nativeRuntimeActive && state.nativeRuntimeSession?.contentCache != true {
                    Text("消息扩展 Hook 未加载：内容缓存、关键词和红包功能暂不可用。请先重启微信后重新注入；防撤回可独立工作。")
                        .font(.callout).foregroundStyle(.orange)
                }
                Toggle("静默防撤回（不显示拦截提示）", isOn: Binding(
                    get: { silent }, set: { value in Task { await run(["--silent", value ? "on" : "off"]) } }))
                    .disabled(busy || state.busy)
                Toggle("屏蔽微信更新检查与自动下载", isOn: Binding(
                    get: { blockUpdates }, set: { value in Task { await run(["--block-update", value ? "on" : "off"]) } }))
                    .disabled(busy || state.busy || (!blockUpdates && !canBlockUpdates))
                Text("选项保存到微信偏好设置，加载后约一秒生效。不修改微信 App。已在注入前开始的更新下载不会被撤销。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.callout).foregroundStyle(.orange) }
                Button("刷新动态功能状态") { Task { await run(["get"]) } }.disabled(busy)
            }
        }
        .task(id: state.appPath) { await run(["get"]) }
        .onChange(of: state.nativeRuntimeSession?.components) { _ in Task { await run(["get"]) } }
    }

    @MainActor private func run(_ arguments: [String]) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let result = await CLIRunner.runUser(BundledPaths.cli,
            ["native-options"] + arguments + ["--app", state.appPath, "--json"])
        if result.succeeded, let report = try? JSONDecoder().decode(Report.self, from: Data(result.output.utf8)) {
            silent = report.silent; blockUpdates = report.blockUpdates; canBlockUpdates = report.canBlockUpdates
            error = nil
        } else { error = result.output + result.stderr }
    }
}
