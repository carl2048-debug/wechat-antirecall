import SwiftUI

struct RestoreView: View {
    @EnvironmentObject var state: AppState
    @State private var sessions: [BackupSession] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("恢复 / 卸载").font(.title2.weight(.semibold))

            if let banner = state.banner {
                BannerView(banner: banner)
            }

            if state.isNativeBuild {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "停用动态注入")
                        Text("当前动态模式没有修改微信 App。完全退出微信即可停用本次注入；偏好设置会保留，下次直接打开微信不会自动注入。下方备份仅用于恢复以前安装的静态补丁。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("退出微信并停用本次注入") { Task { await state.quitWeChat() } }
                            .disabled(state.busy || !state.wechatRunning)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "从备份还原")
                    Text("每次打补丁都会在被修改文件旁生成备份。每个备份会还原到该次操作开始前的状态；如果后续模式叠加在更早的补丁上，可能还需继续还原对应的更早备份，才能完全回到原版微信。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    KeyValueRow(key: "当前微信 App", value: state.appPath, mono: true)
                    if state.wechatRunning {
                        HintRow(systemImage: "exclamationmark.circle.fill", text: "恢复前请先退出微信。", tint: .orange)
                    }
                }
            }

            if sessions.isEmpty {
                Card {
                    HStack(spacing: 10) {
                        Image(systemName: "tray").foregroundStyle(.secondary)
                        Text("没有找到备份。可能还没打过补丁，或备份已被清理。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                ForEach(sessions) { session in
                    sessionCard(session)
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: state.busy) { busy in
            if !busy { reload() }
        }
        .onChange(of: state.appPath) { _ in reload() }
    }

    private func sessionCard(_ session: BackupSession) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.displayDate).font(.subheadline.weight(.semibold))
                        Text("\(session.entries.count) 个文件").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task {
                            await state.restore(session: session)
                            reload()
                        }
                    } label: {
                        Label("还原这一次", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(state.busy || state.wechatRunning)
                }
                ForEach(session.entries) { entry in
                    HStack {
                        Image(systemName: "doc").font(.caption).foregroundStyle(.secondary)
                        Text(entry.binaryRelativePath).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Text(byteString(entry.sizeBytes)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func reload() {
        sessions = BackupBrowser.sessions(appPath: state.appPath)
    }

    private func byteString(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
