import AppKit
import SessionHopperCore
import XCTest
@testable import AgentsSessionHopper

@MainActor
final class StatusMenuTests: XCTestCase {
    func testMenuLayout() {
        let m = StatusMenu.shared.menu()
        XCTAssertEqual(m.items.map { $0.isSeparatorItem ? "-" : $0.title }, [
            "Open", "Settings…", "Show Hand-off Log", "-", "Request a feature", "Contribute",
            "About AgentsSessionHopper", "Support on Ko-fi ☕", "-", "Quit AgentsSessionHopper"])
        XCTAssertEqual(m.items.last?.keyEquivalent, "q")
        XCTAssertTrue(m.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.action != nil && $0.target != nil })
    }

    /// Regression (0.1.4): Settings… / Switch log… did nothing, `showSettingsWindow:` is ignored on macOS 14+.
    func testSettingsItemsOpenWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hopper-menu-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: root) }
        SettingsWindow.model = AppModel(env: HopperEnvironment(home: root, stateDir: root, selfPath: "/usr/bin/true"), autoRefresh: false)
        _ = NSApplication.shared  // xctest has no NSApp until something asks for it
        let item = try XCTUnwrap(StatusMenu.shared.menu().items.first { $0.title == "Show Hand-off Log" })
        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
        let w = try XCTUnwrap(NSApp.windows.first { $0.title == "Log" })
        XCTAssertTrue(w.isVisible)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))  // hosting controller sizes the window on a later pass
        XCTAssertGreaterThan(w.frame.height, 300)
        w.close()
    }
}
