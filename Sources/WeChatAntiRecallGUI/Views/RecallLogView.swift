import SwiftUI
import AppKit

struct RecallLogView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var controller = RecallLogController()
    @State private var confirmingClear = false

    private var runtimeInstalled: Bool {
        controller.runtimeAvailable && (state.nativeRuntimeActive || (state.installedMode == .customTip && state.installState == .installed))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            HStack {
                Text("撤回记录").font(.title2.weight(.semibold))
                StatusPill(tone: controller.enabled ? .good : .neutral,
                           text: controller.enabled ? "记录中" : "已关闭",
                           systemImage: controller.enabled ? "record.circle" : "pause.circle")
            }
            Text("开启后，每次拦截到别人撤回消息，都会在本机留一条记录：谁撤回了什么、什么时候。默认关闭。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let banner = state.banner { BannerView(banner: banner) }
            if let error = controller.error {
                HintRow(systemImage: "exclamationmark.circle", text: error, tint: .orange)
                Button("重新读取") { Task { await controller.load(appPath: state.appPath) } }
                    .disabled(controller.busy)
                if controller.needsDiskAccess {
                    Button("打开完全磁盘访问设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            settingsCard
            recordsCard
        }
        .task(id: state.appPath) { await controller.load(appPath: state.appPath) }
        .alert("清空撤回记录？", isPresented: $confirmingClear) {
            Button("清空", role: .destructive) { Task { await controller.clear(appPath: state.appPath) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除本机保存的全部撤回记录，无法恢复。")
        }
    }

    private var settingsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("记录被拦截的撤回", isOn: Binding(
                    get: { controller.enabled },
                    set: { newValue in
                        // Without the runtime component only turning off is reachable,
                        // mirroring the red-packet switch.
                        guard !newValue || runtimeInstalled else { return }
                        Task { await controller.setEnabled(newValue, appPath: state.appPath) }
                    }
                ))
                .toggleStyle(.switch)
                .disabled(controller.busy || state.busy || (!controller.enabled && !runtimeInstalled))
                if !runtimeInstalled && controller.error == nil && !controller.busy {
                    Text("需要先加载运行组件。当前原生注入版本请回首页注入，无需修改微信 App。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button(controller.runtimeAvailable ? "安装运行组件" : "安装或更新运行组件") {
                        Task {
                            if state.isNativeBuild { await state.launchDynamically() }
                            else { await state.install(InstallRequest(mode: .customTip), refreshRuntime: true) }
                            await controller.load(appPath: state.appPath)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.busy || controller.busy || (!state.isNativeBuild && (state.wechatRunning || !state.customTipAvailable)))
                    if state.wechatRunning && !state.isNativeBuild {
                        Button("退出微信") { Task { await state.quitWeChat() } }.disabled(state.busy)
                    }
                }
                HintRow(systemImage: "lock.shield",
                        text: "记录只保存在微信自己的容器目录里，不会上传。内容预览只覆盖本次启动微信后收到的消息，其余显示为“未知”。",
                        tint: .secondary)
                if let message = controller.message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var recordsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel(text: "最近的撤回")
                    Spacer()
                    Button("刷新") { Task { await controller.load(appPath: state.appPath) } }
                        .disabled(controller.busy)
                    Button("清空…", role: .destructive) { confirmingClear = true }
                        .disabled(controller.busy || controller.total == 0)
                }
                if controller.entries.isEmpty {
                    Text(controller.busy ? "正在读取…" : "还没有记录。")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(controller.entries) { record in
                            recordRow(record)
                            if record.id != controller.entries.last?.id { Divider() }
                        }
                    }
                    if controller.total > controller.entries.count {
                        Text("仅显示最近 \(controller.entries.count) 条，共 \(controller.total) 条。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if controller.unreadableLines > 0 {
                        Text("另有 \(controller.unreadableLines) 行无法解析，已跳过。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func recordRow(_ record: RecallLogController.Record) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.notice.isEmpty ? "（无提示文本）" : record.notice)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                Text(Self.timeFormatter.string(from: record.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(record.content.map { $0.isEmpty ? "（空）" : $0 } ?? "内容未知")
                .font(.callout)
                .foregroundStyle(record.content == nil ? .tertiary : .secondary)
                .textSelection(.enabled)
            Text("\(record.isGroup ? "群聊" : "会话") \(record.session)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 8)
    }
}
