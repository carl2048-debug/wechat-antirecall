import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject var state: AppState
    var goToCustomTip: () -> Void
    var goToAdvanced: () -> Void
    var goToUpdates: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            if let banner = state.banner {
                BannerView(banner: banner)
            }

            statusCard

            if state.isNativeBuild {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel(text: "原生动态注入（实验性）")
                        Text("将插件加载到当前微信进程，不修改微信 App 或签名。需要管理员授权及系统允许进程注入；退出微信后失效。微信未启动时会先打开微信。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("注入微信 · 开启防撤回") {
                            Task { await state.launchDynamically() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.busy)
                        Text("设置位于下方及左侧功能页。当前版本不使用静态安装。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                NativeOptionsView()
            }

            if !state.isNativeBuild {
            switch state.supportStatus {
            case .supported:
                if state.customTipNeedsRestore {
                    customTipResidualCard
                } else if state.installedMode == .customTip || state.silentAvailable {
                    supportedActions
                } else {
                    silentUnavailableCard
                }
            case .unsupported(let build):
                unsupportedCard(build: build)
            case .noWeChat:
                noWeChatCard
            case .failed:
                detectionFailedCard
            case .unknown:
                Card { ProgressView().controlSize(.small) }
            }
            }
        }
    }

    // MARK: - Status card

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Theme.accent.opacity(0.12)))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("微信 \(state.displayVersion)")
                            .font(.title3.weight(.semibold))
                        Text("构建号 \(state.displayBuild)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 6) {
                        supportPill
                        if state.busy {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(state.busyMessage).font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Button {
                                Task { await state.refresh() }
                            } label: {
                                Label("刷新", systemImage: "arrow.clockwise").font(.caption)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }

                Divider()

                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前微信 App")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(state.appPath)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(state.appPath)
                    }
                    Spacer(minLength: 12)
                    Button("选择…", action: chooseTargetApp)
                        .buttonStyle(.bordered)
                        .disabled(state.busy)
                    Button("恢复默认") {
                        Task { await state.resetTargetApp() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.busy || state.isUsingDefaultAppPath)
                }
            }
        }
    }

    private var supportPill: some View {
        if state.isNativeBuild {
            return AnyView(StatusPill(tone: .good, text: "支持原生注入", systemImage: "checkmark.seal.fill"))
        }
        switch state.supportStatus {
        case .supported:
            return AnyView(StatusPill(tone: .good, text: "此版本受支持", systemImage: "checkmark.seal.fill"))
        case .unsupported:
            return AnyView(StatusPill(tone: .warn, text: "暂不支持", systemImage: "exclamationmark.triangle.fill"))
        case .noWeChat:
            return AnyView(StatusPill(tone: .neutral, text: "未检测到微信", systemImage: "questionmark.circle"))
        case .failed:
            return AnyView(StatusPill(tone: .bad, text: "检测失败", systemImage: "exclamationmark.triangle.fill"))
        case .unknown:
            return AnyView(StatusPill(tone: .neutral, text: "检测中…"))
        }
    }

    // MARK: - Supported

    private var supportedActions: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionLabel(text: activeMode.title)
                    Spacer()
                    installStatePill
                }
                Text(activeMode.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if state.wechatRunning {
                    HStack(spacing: 10) {
                        HintRow(systemImage: "exclamationmark.circle.fill",
                                text: "安装前请先完全退出微信。", tint: .orange)
                        Button("退出微信") { Task { await state.quitWeChat() } }
                            .disabled(state.busy)
                    }
                }

                if state.installedMode == .customTip {
                    Button(action: goToCustomTip) {
                        Label("修改自定义提示", systemImage: "text.bubble")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Theme.accent)
                } else {
                    Button {
                        Task { await state.install(InstallRequest(mode: .silent)) }
                    } label: {
                        Text(state.installState == .installed ? "重新安装防撤回" : "开启静默防撤回")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Theme.accent)
                    .disabled(state.busy || state.wechatRunning)
                }

                HStack(spacing: 12) {
                    if state.installedMode != .customTip && state.customTipAvailable {
                        Button("使用自定义提示") { goToCustomTip() }
                            .buttonStyle(.link)
                    }
                    Button("更多安装选项") { goToAdvanced() }
                        .buttonStyle(.link)
                }

                HintRow(systemImage: "info.circle",
                        text: state.installedMode == .customTip
                            ? "自定义提示运行时已安装；修改短语后完全退出并重开微信即可生效。"
                            : "安装会修改并重新签名微信。装完请完全退出并重开微信。")
            }
        }
    }

    private var activeMode: InstallMode {
        state.installedMode ?? .silent
    }

    private var installStatePill: some View {
        switch state.installState {
        case .installed:
            let text = state.installedMode == .customTip ? "自定义提示已开启" : "静默模式已开启"
            return AnyView(StatusPill(tone: .good, text: text, systemImage: "checkmark.circle.fill"))
        case .notInstalled: return AnyView(StatusPill(tone: .neutral, text: "未开启"))
        case .mismatch: return AnyView(StatusPill(tone: .warn, text: "数据不匹配"))
        case .unknown: return AnyView(EmptyView())
        }
    }

    // MARK: - Unsupported / no WeChat

    private var customTipResidualCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "检测到不一致的自定义提示状态")
                Text("部分自定义提示运行时或 hook 已存在，不能直接覆盖为静默模式。请到「恢复 / 卸载」还原对应备份。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("查看高级安装指引", action: goToAdvanced)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var silentUnavailableCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "当前版本没有静默防撤回")
                Text("补丁数据识别了这个微信构建，但没有提供静默防撤回所需的完整补丁点。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.customTipAvailable {
                    Button("使用自定义提示", action: goToCustomTip)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                } else {
                    Button("查看可用安装模式", action: goToAdvanced)
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var detectionFailedCard: some View {
        Card {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "未能完成检测")
                    Text("请按上方提示处理后重新检测，或选择另一个官方微信 App。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新检测") { Task { await state.refresh() } }
                    .buttonStyle(.bordered)
                    .disabled(state.busy)
            }
        }
    }

    private func unsupportedCard(build: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "此版本暂不支持")
                Text("当前微信构建号 \(build) 还不在补丁数据里。支持新版本通常只需要更新一份很小的补丁数据——先试试拉取最新数据。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button {
                        Task { await state.updatePatchData() }
                    } label: {
                        Label("拉取最新补丁数据", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(state.busy)

                    Button("更多更新选项") { goToUpdates() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var noWeChatCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "未检测到微信")
                Text("没有在 \(state.appPath) 找到微信。请确认已安装 macOS 版微信 4。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("重新检测") { Task { await state.refresh() } }
                    .disabled(state.busy)
            }
        }
    }

    private func chooseTargetApp() {
        let panel = NSOpenPanel()
        panel.title = "选择官方 macOS 微信"
        panel.message = "请选择微信 App。本轮不支持选择多开副本。"
        panel.prompt = "选择"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: state.appPath).deletingLastPathComponent()

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.selectTargetApp(at: url) }
    }
}
