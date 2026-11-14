import Foundation
import XCTest
@testable import AgentsSessionHopper
@testable import SessionHopperCore

final class SupportPromptTests: XCTestCase {
    private let day = SupportPromptState.day
    private let install = Date(timeIntervalSince1970: 1_794_528_000)  // 2026-11-13 (UTC)

    private func mayAsk(_ s: SupportPromptState, day d: Double, hops: Int = 20, version: String = "1.11.0") -> Bool {
        s.mayAsk(now: install.addingTimeInterval(d * day), installDate: install, hops: hops, appVersion: version)
    }

    func testFirstAskNeedsSevenDaysAndMoreThanTenHops() {
        let s = SupportPromptState()
        XCTAssertFalse(mayAsk(s, day: 6.9))
        XCTAssertFalse(mayAsk(s, day: 60, hops: 10), "never at 10 hops or fewer, however long installed")
        XCTAssertTrue(mayAsk(s, day: 7, hops: 11))
    }

    func testSnoozeHidesFourteenDays() {
        var s = SupportPromptState()
        s.record(.snooze, now: install.addingTimeInterval(10 * day), appVersion: "1.11.0")
        XCTAssertFalse(mayAsk(s, day: 23.9))
        XCTAssertTrue(mayAsk(s, day: 24))
    }

    func testSupportQuietFor180Days() {
        var s = SupportPromptState()
        s.record(.support, now: install.addingTimeInterval(10 * day), appVersion: "1.11.0")
        XCTAssertFalse(mayAsk(s, day: 189))
        XCTAssertTrue(mayAsk(s, day: 190))
    }

    func testNeverLastsUntilNextMajorAndNinetyDays() {
        var s = SupportPromptState()
        s.record(.never, now: install.addingTimeInterval(10 * day), appVersion: "1.11.0")
        XCTAssertFalse(mayAsk(s, day: 300, version: "1.12.0"), "a feature release must not undo 'never'")
        XCTAssertFalse(mayAsk(s, day: 50, version: "2.0.0"), "a major release within 90 days must not undo it")
        XCTAssertTrue(mayAsk(s, day: 100, version: "2.0.0"))
    }

    func testAtMostThreeAsksPerRolling365Days() {
        var s = SupportPromptState()
        for d in [10.0, 40, 70] { s.recordShown(install.addingTimeInterval(d * day)) }
        XCTAssertFalse(mayAsk(s, day: 300))
        XCTAssertTrue(mayAsk(s, day: 376), "the first ask has rolled out of the window")
    }

    func testOldOrPartialStateDecodes() throws {
        XCTAssertEqual(try JSONDecoder().decode(SupportPromptState.self, from: Data("{}".utf8)), SupportPromptState())
        let snoozed = try JSONDecoder().decode(SupportPromptState.self, from: Data(#"{"snoozedUntil":0}"#.utf8))
        XCTAssertEqual(snoozed.snoozedUntil, Date(timeIntervalSinceReferenceDate: 0), "known keys survive missing ones")
        XCTAssertEqual(snoozed.shownAt, [])
    }

    // MARK: hops and calm

    private let t0 = 1_794_528_000.0
    private func event(_ type: String, _ session: String, at t: Double, from: String? = nil, to: String? = nil, trigger: String? = nil) -> HopperEvent {
        HopperEvent(type: type, session: session, from: from, to: to, trigger: trigger,
                    ts: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: t)))
    }
    private func live(_ session: String, on profile: String, child: Int32 = getpid(), waiting: Double? = nil) -> LiveSession {
        LiveSession(record: SessionRecord(session: session, resume: session, pid: getpid(), child: child, profile: profile,
                                          cwd: "/Users/me/Code/app", started: "x"),
                    busy: false, held: false, pending: nil, suggestion: nil, waitingUntil: waiting)
    }
    private func snapshot(_ events: [HopperEvent], _ sessions: [LiveSession] = [], at t: Double) -> HopperSnapshot {
        HopperSnapshot(config: HopperConfig(), limits: [:], sessions: sessions, events: events, now: t)
    }

    func testHopCountsWhenTheConversationStillRunsThereThirtySecondsLater() {
        var c = HopCounter()
        let old = event("switch", "s0", at: t0 - 600, from: "a", to: "b")
        XCTAssertEqual(c.update(snapshot([old], at: t0)).hops, 0, "hops logged before launch are not news")
        let hop = event("switch", "s1", at: t0 + 1, from: "a", to: "b")
        XCTAssertEqual(c.update(snapshot([old, hop], [live("s1", on: "b")], at: t0 + 2)).hops, 0, "not yet 30 s")
        XCTAssertEqual(c.update(snapshot([old, hop], [live("s1", on: "b")], at: t0 + 32)).hops, 1)
        XCTAssertEqual(c.update(snapshot([old, hop], [live("s1", on: "b")], at: t0 + 34)).hops, 0, "counted once")
    }

    func testFailedOrUnprovenHopsDoNotCount() {
        var c = HopCounter()
        _ = c.update(snapshot([], at: t0))
        let gone = event("switch", "s1", at: t0, from: "a", to: "b")
        let parked = event("switch", "s2", at: t0, from: "a", to: "b")
        let park = event("park", "s2", at: t0 + 5, from: "b")
        let waiting = event("switch", "s3", at: t0, from: "a", to: "b")
        let deadChild = event("switch", "s4", at: t0, from: "a", to: "b")
        let events = [gone, parked, park, waiting, deadChild]
        let sessions = [live("s2", on: "b"), live("s3", on: "b", waiting: t0 + 3600), live("s4", on: "b", child: 0)]
        XCTAssertTrue(c.update(snapshot(events, sessions, at: t0 + 6)).trouble, "a park is trouble")
        let r = c.update(snapshot(events, sessions, at: t0 + 40))
        XCTAssertEqual(r.hops, 0, "session ended, parked, waiting for a reset, or its claude gone")
        XCTAssertFalse(r.trouble)
    }

    func testRunServedAfterARetryCountsAtOnce() {
        var c = HopCounter()
        _ = c.update(snapshot([], at: t0))
        let retried = event("run", "r1", at: t0, from: "a", to: "b", trigger: "ok")
        let plain = event("run", "r2", at: t0, to: "a", trigger: "ok")
        let failed = event("run", "r3", at: t0, from: "a", to: "b", trigger: "error")
        let r = c.update(snapshot([retried, plain, failed], at: t0 + 1))
        XCTAssertEqual(r.hops, 1)
        XCTAssertTrue(r.trouble, "a failed run is trouble")
        let stop = event("limit", "r4", at: t0 + 2, from: "a")
        let served = event("run", "r4", at: t0 + 3, from: "a", to: "b", trigger: "ok")
        let r2 = c.update(snapshot([retried, plain, failed, stop, served], at: t0 + 4))
        XCTAssertEqual(r2.hops, 1)
        XCTAssertFalse(r2.trouble, "the limit stop a retry got past")
    }

    func testCalmOnlyWhenNothingNeedsTheUser() {
        var config = HopperConfig()
        config.profiles = [Profile(name: "a", dir: "/Users/me/.claude", exportConfigDir: false),
                           Profile(name: "b", dir: "/Users/me/.claude-b", exportConfigDir: true)]
        func limits(_ pct: Double) -> ProfileLimits {
            ProfileLimits(fiveHour: LimitWindow(usedPercentage: pct, resetsAt: t0 + 3600), sevenDay: nil, sampledAt: t0)
        }
        func s(_ a: Double, _ b: Double, _ sessions: [LiveSession]) -> HopperSnapshot {
            HopperSnapshot(config: config, limits: ["a": limits(a), "b": limits(b)], sessions: sessions, events: [], now: t0)
        }
        XCTAssertTrue(s(99, 40, [live("s1", on: "b")]).isCalm, "the profile left behind may be full")
        XCTAssertFalse(s(99, 90, [live("s1", on: "b")]).isCalm, "a profile in use near its limit")
        XCTAssertFalse(s(99, 98, []).isCalm, "every profile full")
        var asked = live("s1", on: "b")
        asked.suggestion = Suggestion(from: "b", to: "a", percent: 86, reason: "threshold")
        XCTAssertFalse(s(10, 40, [asked]).isCalm, "a suggestion waits for the user")
        XCTAssertFalse(s(10, 40, [live("s1", on: "b", waiting: t0 + 60)]).isCalm, "a parked session")
        // b's 5-hour window opened 1 h ago at 60%: at that pace it reaches 85% in ~25 min.
        let fast = ProfileLimits(fiveHour: LimitWindow(usedPercentage: 60, resetsAt: t0 + 4 * 3600), sevenDay: nil, sampledAt: t0)
        let paced = HopperSnapshot(config: config, limits: ["a": limits(10), "b": fast], sessions: [live("s1", on: "b")], events: [], now: t0)
        XCTAssertFalse(paced.isCalm, "a profile in use on pace to reach the suggest threshold within the hour")
        let slow = ProfileLimits(fiveHour: LimitWindow(usedPercentage: 10, resetsAt: t0 + 4 * 3600), sevenDay: nil, sampledAt: t0)
        XCTAssertTrue(HopperSnapshot(config: config, limits: ["a": limits(10), "b": slow], sessions: [live("s1", on: "b")], events: [], now: t0).isCalm)
    }

    func testArmedForTwelveHoursAfterTheHop() {
        let hop = Date(timeIntervalSince1970: t0)
        XCTAssertFalse(SupportPrompt.armed(nil, now: hop))
        XCTAssertTrue(SupportPrompt.armed(hop, now: hop.addingTimeInterval(12 * 3600 - 1)))
        XCTAssertFalse(SupportPrompt.armed(hop, now: hop.addingTimeInterval(12 * 3600)))
    }

    func testQuietForCountsFromTheNewestEvent() {
        XCTAssertEqual(snapshot([], at: t0).quietFor, .infinity)
        let s = snapshot([event("suggest", "s1", at: t0 - 300), event("switch", "s1", at: t0 - 60, from: "a", to: "b")], at: t0)
        XCTAssertEqual(s.quietFor, 60, accuracy: 1)
    }
}
