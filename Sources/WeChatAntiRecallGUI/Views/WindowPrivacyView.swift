import SwiftUI

struct WindowPrivacyView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var controller = WindowPrivacyController()

    private var runtimeInstalled: Bool {
        controller.runtimeAvailable && (state.nativeRuntimeActive || (state.installedMode == .customTip && state.installState == .installed))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            HStack {
                Text("窗口隐私").font(.title2.weight(.semibold))
                StatusPill(tone: controller.enabled ? .good : .neutral,
                           text: controller.enabled ? "已开启" : "已关闭",
                           systemImage: controller.enabled ? "eye.slash.fill" : "eye")
            }
            Text("共享屏幕、录屏或被其他软件截图时，让所有微信窗口都不出现在画面里。默认关闭。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let banner = state.banner { BannerView(banner: banner) }
            if let error = controller.error {
                HintRow(systemImage: "exclamationmark.circle", text: error, tint: .orange)
                Button("重新读取设置") { Task { await controller.load(appPath: state.appPath) } }
                    .disabled(controller.busy)
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("共享屏幕、录屏时隐藏微信窗口", isOn: Binding(
                        get: { controller.enabled },
                        set: { newValue in
                            // Without the runtime component only turning off is reachable,
                            // mirroring the other switches.
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
                    if let message = controller.message {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "说明与限制")
                    HintRow(systemImage: "macwindow.on.rectangle",
                            text: "微信自带的“隐藏窗口截图”选项只覆盖主窗口；这里会覆盖所有微信窗口，包括单独打开的聊天窗口、图片查看器和朋友圈。")
                    HintRow(systemImage: "camera.metering.unknown",
                            text: "微信自带的截图和录屏也会看不到微信窗口。需要截微信自己的界面时请先关闭。")
                    HintRow(systemImage: "bell.badge",
                            text: "macOS 的通知横幅由系统绘制，不受影响。共享屏幕前请自行打开“勿扰”。")
                    HintRow(systemImage: "info.circle",
                            text: "这是 macOS 提供的窗口属性，效果取决于录屏或共享软件以及系统版本，不能当作安全保证。新窗口出现的瞬间可能有极短的露出。")
                    HintRow(systemImage: "arrow.uturn.backward",
                            text: "关闭后会把本工具改过的窗口恢复原状，不会改动微信自己已经隐藏的窗口。")
                }
            }
        }
        .task(id: state.appPath) { await controller.load(appPath: state.appPath) }
    }
}
