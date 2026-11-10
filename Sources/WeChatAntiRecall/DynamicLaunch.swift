import Foundation
import Darwin
import WeChatNativeInjector
import WeChatRuntimeSession

struct DynamicLaunchOptions {
    var appPath = "/Applications/WeChat.app"
    var runtimePath: String

    init(_ arguments: [String]) throws {
        var runtime: String?
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard ["--app", "--runtime-dylib"].contains(flag), index + 1 < arguments.count else {
                throw ToolError.usage("launch 只接受 --app <路径> 和 --runtime-dylib <路径>；不会执行静态安装")
            }
            index += 1
            if flag == "--app" { appPath = arguments[index] }
            else { runtime = arguments[index] }
            index += 1
        }
        guard let runtime, !runtime.isEmpty else {
            throw ToolError.usage("请通过 --runtime-dylib 指定微信 App 外的 runtime dylib")
        }
        runtimePath = runtime
    }
}

enum DynamicLauncher {
    static func validateRuntime(appURL: URL, runtimeURL: URL) throws {
        let app = appURL.resolvingSymlinksInPath().standardizedFileURL.path
        let runtime = runtimeURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard !runtime.hasPrefix(app + "/"), runtime != app else {
            throw ToolError.usage("动态模式的 runtime 必须放在微信 App 外")
        }
        guard FileManager.default.isReadableFile(atPath: runtime) else {
            throw ToolError.usage("无法读取 runtime：\(runtime)")
        }
    }

    static func launch(app: AppInfo, options: DynamicLaunchOptions) throws {
        guard NativeRuntimeSession.supportedBuilds.contains(app.buildVersion) else {
            throw ToolError.usage("原生注入支持构建 268602、270353，当前为 \(app.buildVersion)。未修改微信文件。")
        }
        let runtime = URL(fileURLWithPath: options.runtimePath).standardizedFileURL.resolvingSymlinksInPath()
        try validateRuntime(appURL: app.appURL, runtimeURL: runtime)
        let executable = app.executableURL.resolvingSymlinksInPath().path
        var pid = executable.withCString { wechat_find_main_process($0) }
        if pid == 0 {
            guard geteuid() != 0 else {
                throw ToolError.usage("请先以普通用户打开微信，或从 GUI 点击「注入微信」；不要以 root 身份启动微信。")
            }
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-a", app.appURL.path]
            try open.run()
            open.waitUntilExit()
            guard open.terminationStatus == 0 else { throw ToolError.usage("无法启动微信") }
            for _ in 0..<100 {
                pid = executable.withCString { wechat_find_main_process($0) }
                if pid != 0 { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        guard pid > 0 else {
            throw ToolError.usage(pid == -2 ? "发现多个微信主进程，请只保留一个再注入" : "找不到目标微信主进程")
        }
        print("正在向微信主进程 PID \(pid) 原生注入；不使用 LLDB，不修改或重签微信 App。")
        var error = [CChar](repeating: 0, count: 2048)
        let result = executable.withCString { executablePointer in
            runtime.path.withCString { runtimePointer in
                wechat_inject_runtime(pid, executablePointer, runtimePointer, &error, error.count)
            }
        }
        guard result == 1 else { throw ToolError.usage(String(cString: error)) }
        print("插件已加载，防撤回 Hook 已确认启用。退出微信后失效。")
    }
}
