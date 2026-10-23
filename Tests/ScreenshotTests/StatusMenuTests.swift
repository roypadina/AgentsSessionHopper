import AppKit
import XCTest
@testable import AgentsSessionHopper

@MainActor
final class StatusMenuTests: XCTestCase {
    func testMenuLayout() {
        let m = StatusMenu.shared.menu()
        XCTAssertEqual(m.items.map { $0.isSeparatorItem ? "-" : $0.title }, [
            "Open", "Settings…", "Switch log…", "-", "Request a feature", "Contribute",
            "About AgentsSessionHopper", "Support on Ko-fi ☕", "-", "Quit AgentsSessionHopper"])
        XCTAssertEqual(m.items.last?.keyEquivalent, "q")
        XCTAssertTrue(m.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.action != nil && $0.target != nil })
    }
}
