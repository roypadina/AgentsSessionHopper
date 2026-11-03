import XCTest
@testable import SessionHopperCore

/// c1, c2 priority 1; c3 priority 2; OpenRouter (default 10).
final class PriorityTests: XCTestCase {
    let c1 = profile("c1"), c2 = profile("c2")
    let c3 = Profile(name: "c3", dir: "/p/c3", exportConfigDir: true, priority: 2)
    let or = Profile(name: "or", dir: "/p/c1", exportConfigDir: true, kind: Gateway.openRouter)
    var order: [Profile] { [or, c3, c1, c2] } // list order deliberately mixed: priority decides

    func policy(_ l: [String: ProfileLimits], auto: Bool = true) -> Policy {
        var c = HopperConfig()
        c.profiles = order
        c.autoMove = auto
        return Policy(config: c, limits: l, now: 0)
    }

    func testPickFollowsPriorityLevels() {
        XCTAssertEqual(policy([:]).pick(order)?.name, "c1")
        XCTAssertEqual(policy(["c1": limits(98)]).pick(order)?.name, "c2")
        XCTAssertEqual(policy(["c1": limits(98), "c2": limits(99)]).pick(order)?.name, "c3")
        XCTAssertEqual(policy(["c1": limits(98), "c2": limits(99), "c3": limits(97)]).pick(order)?.name, "or")
    }

    func testEqualPrioritiesDoNotTradePlacesBeforeALimit() {
        // On c2 since c1 filled up; c1 has reset: stay on c2 until it is full.
        XCTAssertEqual(policy([:]).pick(order, current: "c2")?.name, "c2")
        XCTAssertEqual(policy(["c2": limits(92)]).pick(order, current: "c2")?.name, "c2", "between the thresholds still counts as room")
        XCTAssertEqual(policy(["c2": limits(97)]).pick(order, current: "c2")?.name, "c1")
        XCTAssertEqual(policy([:]).evaluate(current: c2, order: order, held: false), .none)
    }

    func testABetterPriorityThatFreesUpIsMovedBackTo() {
        XCTAssertEqual(policy(["c1": limits(98)]).evaluate(current: c3, order: order, held: false), .autoMove(to: "c2", percent: 0))
        XCTAssertEqual(policy(["c1": limits(98), "c2": limits(98)]).evaluate(current: c3, order: order, held: false), .none)
        XCTAssertEqual(policy([:]).pick(order, current: "c3")?.name, "c1", "run: a lower level is left as soon as a better one has room")
        // From OpenRouter: c1/c2 first, else c3.
        XCTAssertEqual(policy(["c1": limits(98)]).evaluate(current: or, order: order, held: false), .autoMove(to: "c2", percent: 0))
        XCTAssertEqual(policy(["c1": limits(98), "c2": limits(98)]).evaluate(current: or, order: order, held: false), .autoMove(to: "c3", percent: 0))
        XCTAssertEqual(policy(["c1": limits(98)], auto: false).evaluate(current: or, order: order, held: false), .suggest(to: "c2", percent: 0))
    }

    func testPriorityIsConfigurableAndOldConfigsKeepTheirMeaning() throws {
        var mixed = HopperConfig()
        mixed.profiles = [Profile(name: "or", dir: "/p", exportConfigDir: false, kind: Gateway.openRouter, priority: 1), c1]
        XCTAssertEqual(Policy(config: mixed, limits: [:], now: 0).pick(mixed.profiles)?.name, "or", "an explicit priority wins")
        let old = try JSONDecoder().decode(HopperConfig.self, from: Data(#"{"profiles":[{"name":"a","dir":"/a","exportConfigDir":true}]}"#.utf8))
        XCTAssertNil(old.profiles[0].priority)
        XCTAssertEqual(Policy(config: old, limits: [:], now: 0).priority(old.profiles[0]), 1)
    }
}
