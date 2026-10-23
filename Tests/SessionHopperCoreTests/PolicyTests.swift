import XCTest
@testable import SessionHopperCore

final class PolicyTests: XCTestCase {
    let a = profile("a"), b = profile("b"), c = profile("c")
    var order: [Profile] { [a, b, c] }

    func policy(_ l: [String: ProfileLimits], auto: Bool = false, park: Bool = true, now: Double = 1000) -> Policy {
        var cfg = HopperConfig()
        cfg.profiles = order
        cfg.autoMove = auto
        cfg.parkBeforePaid = park
        return Policy(config: cfg, limits: l, now: now)
    }

    func testOrderBeatsHeadroom() {
        XCTAssertEqual(policy(["a": limits(80), "b": limits(0)]).pick(order)?.name, "a")
    }

    func testSkipsFullProfileAndPrefersUnderSuggest() {
        XCTAssertEqual(policy(["a": limits(99), "b": limits(90), "c": limits(10)]).pick(order)?.name, "c")
        XCTAssertEqual(policy(["a": limits(99), "b": limits(90), "c": limits(98)]).pick(order)?.name, "b", "past-suggest beats nothing")
        XCTAssertNil(policy(["a": limits(99), "b": limits(97), "c": limits(98)]).pick(order))
    }

    func testUnknownAndResetCountAsRoom() {
        XCTAssertEqual(policy(["a": limits(99)]).pick(order)?.name, "b", "no sample = unknown = room")
        XCTAssertEqual(policy(["a": limits(99, resets: 500)], now: 1000).pick(order)?.name, "a", "window reset since the sample")
    }

    func testFullestLiveWindowCounts() {
        let l = ProfileLimits(fiveHour: LimitWindow(usedPercentage: 20, resetsAt: 2000),
                              sevenDay: LimitWindow(usedPercentage: 91, resetsAt: 9000), sampledAt: 0)
        XCTAssertEqual(l.percent(now: 1000), 91)
        XCTAssertEqual(l.blocking(now: 1000)?.name, "7d")
        XCTAssertEqual(l.percent(now: 9500), nil)
    }

    func testBelowSuggestDoesNothing() {
        XCTAssertEqual(policy(["a": limits(84)]).evaluate(current: a, order: order, held: false), .none)
    }

    func testSuggestByDefault() {
        XCTAssertEqual(policy(["a": limits(88), "b": limits(40)]).evaluate(current: a, order: order, held: false), .suggest(to: "b", percent: 88))
    }

    func testNoSuggestWhenNobodyHasRoom() {
        XCTAssertEqual(policy(["a": limits(88), "b": limits(90), "c": limits(86)]).evaluate(current: a, order: order, held: false), .none)
    }

    func testAutoMoveOnlyWhenOptedIn() {
        XCTAssertEqual(policy(["a": limits(88)], auto: true).evaluate(current: a, order: order, held: false), .autoMove(to: "b", percent: 88))
    }

    func testParkPastHardThreshold() {
        XCTAssertEqual(policy(["a": limits(97), "b": limits(10)]).evaluate(current: a, order: order, held: false), .park(percent: 97))
    }

    func testAutoMovePastHardMovesInsteadOfParking() {
        XCTAssertEqual(policy(["a": limits(98), "b": limits(90), "c": limits(99)], auto: true).evaluate(current: a, order: order, held: false),
                       .autoMove(to: "b", percent: 98), "under hard beats parking")
        XCTAssertEqual(policy(["a": limits(98), "b": limits(99), "c": limits(99)], auto: true).evaluate(current: a, order: order, held: false),
                       .park(percent: 98))
    }

    func testHoldNeverParksOrAutoMoves() {
        XCTAssertEqual(policy(["a": limits(99)], auto: true).evaluate(current: a, order: order, held: true), .suggest(to: "b", percent: 99))
        XCTAssertEqual(policy(["a": limits(99), "b": limits(99), "c": limits(99)]).evaluate(current: a, order: order, held: true), .none)
    }

    func testParkOffJustSuggests() {
        XCTAssertEqual(policy(["a": limits(99)], park: false).evaluate(current: a, order: order, held: false), .suggest(to: "b", percent: 99))
    }

    func testConfigOrder() throws {
        var cfg = HopperConfig()
        cfg.profiles = order
        XCTAssertEqual(try cfg.order(prefer: ["c"], only: false).map(\.name), ["c", "a", "b"])
        XCTAssertEqual(try cfg.order(prefer: ["c", "b"], only: true).map(\.name), ["c", "b"])
        XCTAssertThrowsError(try cfg.order(prefer: ["zz"], only: false))
    }

    func testConfigDefaultsAndValidation() throws {
        let cfg = try JSONDecoder().decode(HopperConfig.self, from: Data(#"{"autoMove":true}"#.utf8))
        XCTAssertEqual(cfg.suggestThreshold, 85)
        XCTAssertEqual(cfg.hardThreshold, 97)
        XCTAssertTrue(cfg.parkBeforePaid)
        XCTAssertTrue(cfg.autoMove)
        XCTAssertFalse(HopperConfig().autoMove, "move without asking is opt-in")
        XCTAssertFalse(HopperConfig().moveNowAtHard, "cutting into a turn is opt-in")
        var bad = HopperConfig()
        bad.suggestThreshold = 98
        let sb = Sandbox()
        XCTAssertThrowsError(try bad.save(sb.env().paths))
    }

    func testLimitsFromStatusLine() {
        let input = json(#"{"session_id":"s1","rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"spend_limit":{"used_percentage":99}}}"#)!
        let l = ProfileLimits.fromStatusLine(input, now: 5)
        XCTAssertEqual(l?.fiveHour, LimitWindow(usedPercentage: 23.5, resetsAt: 1738425600))
        XCTAssertNil(l?.sevenDay)
        XCTAssertEqual(l?.session, "s1")
        XCTAssertNil(ProfileLimits.fromStatusLine(json(#"{"model":{"id":"x"}}"#)!, now: 5), "no rate_limits before the first response")
        XCTAssertNil(ProfileLimits.fromStatusLine(json(#"{"rate_limits":{"spend_limit":{"used_percentage":50}}}"#)!, now: 5), "spend caps are not account windows")
    }

    func testPickerPagesAndPicks() {
        let rows = (1...25).map { "row \($0)" }
        var input = ["m", "12"]
        var shown = ""
        let pick = Picker.choose(count: rows.count, row: { rows[$0] }, read: { input.isEmpty ? nil : input.removeFirst() }, write: { shown += $0 })
        XCTAssertEqual(pick, 11)
        XCTAssertTrue(shown.contains(" 1. row 1\n") && shown.contains("20. row 20\n"))
        XCTAssertFalse(shown.contains("row 21"))
        input = [""]
        XCTAssertNil(Picker.choose(count: rows.count, row: { rows[$0] }, read: { input.isEmpty ? nil : input.removeFirst() }, write: { _ in }))
        input = ["30"]
        XCTAssertNil(Picker.choose(count: rows.count, row: { rows[$0] }, read: { input.isEmpty ? nil : input.removeFirst() }, write: { _ in }), "only rows on screen")
    }
}
