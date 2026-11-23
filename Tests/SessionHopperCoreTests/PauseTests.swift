import XCTest
@testable import SessionHopperCore

final class PauseTests: XCTestCase {
    let now = 1_800_000_000.0

    func policy(_ change: (inout HopperConfig) -> Void, limits: [String: ProfileLimits] = [:]) -> Policy {
        var c = HopperConfig()
        c.profiles = [profile("a"), profile("b"), profile("c")]
        change(&c)
        return Policy(config: c, limits: limits, now: now)
    }

    func testPausedProfileIsNeverPicked() {
        let p = policy { $0.profiles[0].pausedUntil = self.now + 600 }
        XCTAssertEqual(p.pick(p.config.profiles)?.name, "b")
        XCTAssertEqual(policy { $0.profiles[0].pausedUntil = self.now - 1 }.pick(p.config.profiles)?.name, "a", "an ended pause is over")
    }

    func testSessionsLeaveAPausedProfile() {
        var p = policy { $0.profiles[0].pausedUntil = Profile.pausedForever }
        XCTAssertEqual(p.evaluate(current: p.config.profiles[0], order: p.config.profiles, held: false), .suggest(to: "b", percent: 100))
        XCTAssertEqual(p.evaluate(current: p.config.profiles[0], order: p.config.profiles, held: true), .suggest(to: "b", percent: 100), "held: never moved by itself, still asked")
        p.config.autoMove = true
        XCTAssertEqual(p.evaluate(current: p.config.profiles[0], order: p.config.profiles, held: true), .suggest(to: "b", percent: 100))
        XCTAssertEqual(p.evaluate(current: p.config.profiles[0], order: p.config.profiles, held: false), .autoMove(to: "b", percent: 100))
        XCTAssertFalse(p.isUrgent(.autoMove(to: "b", percent: 100), current: p.config.profiles[0]), "a pause waits for the turn end")
        let all = policy { for i in 0..<3 { $0.profiles[i].pausedUntil = self.now + 60 } }
        XCTAssertEqual(all.evaluate(current: all.config.profiles[0], order: all.config.profiles, held: false), .park(percent: 100))
        XCTAssertEqual(all.nextRoom(all.config.profiles)?.at, now + 60)
    }

    func testPauseEnds() {
        let l = ProfileLimits(fiveHour: LimitWindow(usedPercentage: 50, resetsAt: now + 1000), sevenDay: LimitWindow(usedPercentage: 10, resetsAt: now + 90000), sampledAt: now)
        XCTAssertEqual(Profile.pauseEnd("30m", limits: nil, now: now), now + 1800)
        XCTAssertEqual(Profile.pauseEnd("2h", limits: nil, now: now), now + 7200)
        XCTAssertEqual(Profile.pauseEnd("5h-reset", limits: l, now: now), now + 1000)
        XCTAssertEqual(Profile.pauseEnd("weekly-reset", limits: l, now: now), now + 90000)
        XCTAssertNil(Profile.pauseEnd("5h-reset", limits: nil, now: now))
        XCTAssertEqual(Profile.pauseEnd("forever", limits: nil, now: now), Profile.pausedForever)
        XCTAssertNil(Profile.pauseEnd("soon", limits: nil, now: now))
    }

    func testModelOnlyLimitMarksTheModelNotTheProfile() {
        let box = Sandbox()
        let paths = box.env().paths
        var a = OneShot.Attempt()
        a.rejected = ("seven_day_opus", now + 5000)
        OneShot.markFull(profile("b"), .limit(until: now + 5000, weekly: true), attempt: a, paths: paths, now: now, model: "fable")
        XCTAssertNil(LimitStore.read("b", paths), "the account itself still has room")
        XCTAssertTrue(ModelLimits.isFull("b", model: "fable", paths, now: now))
        XCTAssertTrue(ModelLimits.isFull("b", model: "seven_day_opus", paths, now: now))
        XCTAssertFalse(ModelLimits.isFull("b", model: "fable", paths, now: now + 6000), "expires at the reset")
        a.rejected = ("seven_day", now + 5000)
        OneShot.markFull(profile("b"), .limit(until: now + 5000, weekly: true), attempt: a, paths: paths, now: now, model: "fable")
        XCTAssertEqual(LimitStore.read("b", paths)?.sevenDay?.usedPercentage, 100, "an account-wide limit still marks the profile")
        XCTAssertEqual(OneShot.modelArg(["-p", "--model", "fable"]), "fable")
        XCTAssertEqual(OneShot.modelArg(["--model=opus"]), "opus")
    }

    func testSessionRulesReachTheSession() throws {
        let box = Sandbox()
        let env = box.env(["SESSIONHOPPER_PROFILE": "a"])
        var c = HopperConfig()
        c.profiles = [profile("a")]
        c.sessionRules = "Use delegate for Fable."
        try c.save(env.paths)
        XCTAssertTrue(HookHandler.sessionContext(env: env)?.contains("Use delegate for Fable.") == true)
    }
}
