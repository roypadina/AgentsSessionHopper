import XCTest
@testable import SessionHopperCore

final class UsageRefreshTests: XCTestCase {
    func testDueIsMissingOrOldClaudeSamplesOnly() {
        var c = HopperConfig()
        c.profiles = [Profile(name: "fresh", dir: "/a", exportConfigDir: true), Profile(name: "old", dir: "/b", exportConfigDir: true),
                      Profile(name: "none", dir: "/c", exportConfigDir: true),
                      Profile(name: "or", dir: "/d", exportConfigDir: true, kind: Gateway.openRouter)]
        let now = 1_000_000.0
        let sample = { (age: Double) in ProfileLimits(fiveHour: nil, sevenDay: LimitWindow(usedPercentage: 97, resetsAt: now + 86400), sampledAt: now - age) }
        let due = UsageRefresh.due(c, limits: ["fresh": sample(3600), "old": sample(3 * 86400)], now: now).map(\.name)
        XCTAssertEqual(due, ["old", "none"])
        // A profile tried within 6 h is not probed again, even when that probe stored nothing.
        let tried = UsageRefresh.due(c, limits: ["fresh": sample(3600)], tried: ["none": now - 600, "old": now - 7 * 3600], now: now).map(\.name)
        XCTAssertEqual(tried, ["old"])
    }
}
