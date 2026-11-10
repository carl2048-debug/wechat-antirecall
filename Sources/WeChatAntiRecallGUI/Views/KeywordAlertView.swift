import SwiftUI
import AppKit

struct KeywordAlertView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var controller = KeywordAlertController()
    @State private var newKeyword = ""
    @State private var inputProblem: String?

    private var runtimeInstalled: Bool {
        controller.runtimeAvailable && (state.nativeRuntimeActive || (state.installedMode == .customTip && state.installState == .installed))
    }

    private var canAdd: Bool {
        !controller.busy && !state.busy && controller.draftKeywords.count < KeywordAlertController.maximumKeywords
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            HStack {
                Text("关键词提醒").font(.title2.weight(.semibold))
                StatusPill(tone: controller.enabled ? .good : .neutral,
                           text: controller.enabled ? "已开启" : "已关闭",
                           systemImage: controller.enabled ? "bell.badge.fill" : "bell.slash")
                StatusPill(tone: .neutral,
                           text: controller.supported ? "已适配" : "待适配",
                           systemImage: controller.supported ? "checkmark.circle" : "info.circle")
            }
            Text("新收到的文字消息包含你设定的关键词时，弹一条 macOS 系统通知，被静音的群聊也一样。默认关闭。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let banner = state.banner { BannerView(banner: banner) }
            if let error = controller.error {
                HintRow(systemImage: "exclamationmark.circle", text: error, tint: .orange)
                Button("重新读取设置") { Task { await controller.load(appPath: state.appPath) } }
                    .disabled(controller.busy)
            }
            switchCard
            keywordsCard
            notesCard
        }
        .task(id: state.appPath) { await controller.load(appPath: state.appPath) }
    }

    private var switchCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("开启关键词提醒", isOn: Binding(
                    get: { controller.enabled },
                    set: { newValue in
                        // Without the runtime component only turning off is reachable,
                        // mirroring the red-packet switch.
                        guard !newValue || (runtimeInstalled && controller.supported) else { return }
                        Task { await controller.setEnabled(newValue, appPath: state.appPath) }
                    }
                ))
                .toggleStyle(.switch)
                .disabled(controller.busy || state.busy ||
                    (!controller.enabled && (!runtimeInstalled || !controller.supported || controller.draftKeywords.isEmpty)))
                if !controller.enabled && runtimeInstalled && controller.supported && controller.draftKeywords.isEmpty {
                    Text("先在下面添加至少一个关键词。").font(.callout).foregroundStyle(.secondary)
                }
                if controller.supported && !runtimeInstalled && !controller.busy && controller.error == nil {
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
                } else if !controller.supported && !controller.busy && controller.error == nil {
                    Text("当前所选构建尚未适配，无法开启关键词提醒。适配的构建与自动红包相同。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let message = controller.message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var keywordsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "关键词（\(controller.draftKeywords.count)/\(KeywordAlertController.maximumKeywords)）")
                HStack {
                    TextField("输入一个关键词，按回车添加", text: $newKeyword)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addKeyword)
                    Button("添加", action: addKeyword)
                        .disabled(!canAdd || newKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let inputProblem {
                    Text(inputProblem).font(.callout).foregroundStyle(.orange)
                }
                if controller.draftKeywords.isEmpty {
                    Text("还没有关键词。").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(controller.draftKeywords, id: \.self) { keyword in
                            HStack {
                                Text(keyword).textSelection(.enabled)
                                Spacer()
                                Button {
                                    controller.removeDraftKeyword(keyword)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("删除“\(keyword)”")
                                .disabled(controller.busy || state.busy)
                            }
                            .padding(.vertical, 6)
                            if keyword != controller.draftKeywords.last { Divider() }
                        }
                    }
                }
                if controller.hasUnsavedChanges {
                    HStack {
                        Button("保存关键词") { Task { await controller.saveKeywords(appPath: state.appPath) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(controller.busy || state.busy ||
                                (controller.enabled && controller.draftKeywords.isEmpty))
                        Button("放弃修改") { controller.draftKeywords = controller.savedKeywords }
                            .disabled(controller.busy)
                    }
                    if controller.enabled && controller.draftKeywords.isEmpty {
                        Text("开启状态下至少要保留一个关键词；要清空请先关闭提醒。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var notesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "说明")
                HintRow(systemImage: "text.magnifyingglass",
                        text: "只检查文字消息，不区分大小写和全角半角；群聊里不会匹配发送者的账号。有多个关键词命中时，按列表顺序取第一个。")
                HintRow(systemImage: "bell",
                        text: "通知里会显示命中的关键词和消息开头的一小段文字，看不到聊天名称。点击通知会打开微信。")
                HintRow(systemImage: "speaker.wave.2",
                        text: "没有被静音的聊天，可能会同时收到微信自己的通知和这条提醒。")
                HintRow(systemImage: "clock",
                        text: "只提醒开启之后新收到的消息，不会补发历史消息，也不提醒你自己发出的消息。")
                HintRow(systemImage: "lock.shield",
                        text: "匹配在微信进程里完成，消息内容不会保存到文件，也不会上传。")
            }
        }
    }

    private func addKeyword() {
        inputProblem = controller.addDraftKeyword(newKeyword)
        if inputProblem == nil { newKeyword = "" }
    }
}
