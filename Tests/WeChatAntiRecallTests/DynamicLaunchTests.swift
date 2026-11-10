import XCTest
@testable import WeChatAntiRecall
import WeChatAntiRecallRuntime

final class DynamicLaunchTests: XCTestCase {
    func testRejectsStaticInstallFlagsAndMissingRuntime() {
        XCTAssertThrowsError(try DynamicLaunchOptions(["--block-update"]))
        XCTAssertThrowsError(try DynamicLaunchOptions([]))
        XCTAssertThrowsError(try DynamicLaunchOptions(["--app"]))
    }

    func testRejectsRuntimeInsideAppIncludingSymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("WeChat.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let dylib = app.appendingPathComponent("runtime.dylib")
        try Data().write(to: dylib)
        let link = directory.appendingPathComponent("external.dylib")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dylib)
        XCTAssertThrowsError(try DynamicLauncher.validateRuntime(appURL: app, runtimeURL: dylib))
        XCTAssertThrowsError(try DynamicLauncher.validateRuntime(appURL: app, runtimeURL: link))
    }

    func testDynamicHookExecutesTrampolineAndLeavesBackingFileUnchanged() throws {
        #if arch(arm64)
        XCTAssertEqual(wechat_antirecall_dynamic_hook_selftest(), 1)
        #else
        throw XCTSkip("arm64 instruction fixture")
        #endif
    }
}
