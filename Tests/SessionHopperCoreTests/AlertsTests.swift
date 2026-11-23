import XCTest
@testable import SessionHopperCore

final class AlertsTests: XCTestCase {
    let now = 1_800_000_000.0
    /// Kept for the whole test: a dropped Sandbox deletes its folder.
    var box: Sandbox!

    func setup(_ change: (inout HopperConfig) -> Void = { _ in }) -> (Sandbox, HopperEnvironment) {
        box = Sandbox()
        let env = box.env()
        var c = HopperConfig()
        c.profiles = [profile("a"), profile("b"), profile("c")]
        change(&c)
        try! c.save(env.paths)
        return (box, env)
    }

    func move(_ from: String, _ to: String, source: String = "engine", trigger: String = "limit_stop") -> HopperEvent {
        HopperEvent(type: "switch", session: UUID().uuidString, from: from, to: to, trigger: trigger, source: source)
    }

    func testDefaultsAndAllOverridesEveryProfile() {
        var s = AlertSettings()
        XCTAssertEqual(s.effective("a", .noRoom), .init(mac: true, ntfy: false, activeOnly: true))
        XCTAssertEqual(s.effective("a", .switched), .init(mac: false, ntfy: false, activeOnly: true))
        s.set("a", .switched, ntfy: true)
        s.set(AlertSettings.everyProfile, .switched, mac: true)
        XCTAssertTrue(s.effective("b", .switched).mac)
        XCTAssertTrue(s.effective("a", .switched).ntfy, "a's own ntfy box stays")
        s.set("a", .switched, mac: false)
        XCTAssertFalse(s.effective("a", .switched).mac)
        s.set(AlertSettings.everyProfile, .switched, mac: true)
        XCTAssertTrue(s.effective("a", .switched).mac, "setting all clears a's own value for that field")
    }

    func testManySessionsMovingOffOneProfileGiveOneAlert() throws {
        let (_, env) = setup { $0.alerts.set(AlertSettings.everyProfile, .switched, mac: true) }
        try LimitStore.write(ProfileLimits(fiveHour: LimitWindow(usedPercentage: 100, resetsAt: now + 7200), sevenDay: nil, sampledAt: now), profile: "a", env.paths)
        for _ in 0..<5 { Alerts.event(move("a", "b"), env: env, now: now) }
        Alerts.event(move("a", "c"), env: env, now: now + 60)
        var alerts = Alerts.read(env.paths)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].kind, "switch")
        XCTAssertEqual(alerts[0].profile, "a")
        XCTAssertTrue(alerts[0].title.contains("b"))
        XCTAssertTrue(alerts[0].mac)
        XCTAssertFalse(alerts[0].ntfy, "ntfy not set up")

        Alerts.event(move("b", "c"), env: env, now: now + 120)
        Alerts.event(move("a", "b"), env: env, now: now + 7300)
        alerts = Alerts.read(env.paths)
        XCTAssertEqual(alerts.map(\.profile), ["a", "b", "a"], "another profile alerts on its own; a again after its window reset")
    }

    func testMovesTheUserAskedForAreNotAlerts() {
        let (_, env) = setup { $0.alerts.set(AlertSettings.everyProfile, .switched, mac: true) }
        Alerts.event(move("a", "b", source: "cli", trigger: "now"), env: env, now: now)
        Alerts.event(move("a", "b", source: "menu", trigger: "confirm"), env: env, now: now)
        XCTAssertTrue(Alerts.read(env.paths).isEmpty)
    }

    func testPerProfileRuleSwitchesOneProfileOff() {
        let (_, env) = setup {
            $0.alerts.set(AlertSettings.everyProfile, .switched, mac: true)
            $0.alerts.set("a", .switched, mac: false)
        }
        Alerts.event(move("a", "b"), env: env, now: now)
        Alerts.event(move("b", "c"), env: env, now: now)
        XCTAssertEqual(Alerts.read(env.paths).map(\.profile), ["b"])
    }

    func testNoRoomOnceUntilAProfileFreesUp() throws {
        let (_, env) = setup()
        for p in ["a", "b", "c"] {
            try LimitStore.write(ProfileLimits(fiveHour: LimitWindow(usedPercentage: 99, resetsAt: now + (p == "b" ? 1800 : 9000)), sevenDay: nil, sampledAt: now), profile: p, env.paths)
        }
        for _ in 0..<3 { Alerts.event(HopperEvent(type: "park", session: "s", from: "a", trigger: "launch", source: "engine"), env: env, now: now) }
        XCTAssertEqual(Alerts.read(env.paths).map(\.kind), ["no-room"], "on by default, once")
        Alerts.event(HopperEvent(type: "park", session: "s", from: "c"), env: env, now: now + 1900)
        XCTAssertEqual(Alerts.read(env.paths).count, 2, "b's window reset at +1800, so a new no-room is news")
    }

    func testUsageOncePerWindowAndLevel() throws {
        let (_, env) = setup {
            $0.alerts.set(AlertSettings.everyProfile, .usageWarning, mac: true, activeOnly: false)
            $0.alerts.set(AlertSettings.everyProfile, .usageCritical, mac: true, activeOnly: false)
        }
        func sample(_ pct: Double, reset: Double) throws {
            try LimitStore.write(ProfileLimits(fiveHour: LimitWindow(usedPercentage: pct, resetsAt: reset), sevenDay: nil, sampledAt: now), profile: "a", env.paths)
            Alerts.usage("a", env: env, now: now)
        }
        try sample(86, reset: now + 3600)
        try sample(88, reset: now + 3601)  // reset times jitter
        try sample(98, reset: now + 3600)
        try sample(99, reset: now + 3600)
        XCTAssertEqual(Alerts.read(env.paths).map(\.kind), ["usage-warning", "usage-critical"])
        try sample(98, reset: now + 3600 + 18000)
        XCTAssertEqual(Alerts.read(env.paths).map(\.kind), ["usage-warning", "usage-critical", "usage-critical"],
                       "a new window: critical again, and no warning after it")
    }

    func testUsageAlertsWaitForASessionHereWhenActiveOnly() throws {
        let (_, env) = setup { $0.alerts.set(AlertSettings.everyProfile, .usageCritical, mac: true) }
        try LimitStore.write(ProfileLimits(fiveHour: LimitWindow(usedPercentage: 99, resetsAt: now + 3600), sevenDay: nil, sampledAt: now), profile: "a", env.paths)
        Alerts.usage("a", env: env, now: now)
        XCTAssertTrue(Alerts.read(env.paths).isEmpty, "no live session on a")
        try FileIO.encode(SessionRecord(session: "s1", resume: "s1", pid: getpid(), child: 0, profile: "a", cwd: "/", started: "x"), to: env.paths.session("s1").record)
        Alerts.usage("a", env: env, now: now)
        XCTAssertEqual(Alerts.read(env.paths).map(\.kind), ["usage-critical"])
    }

    func testFallbackTopicURLSplits() {
        XCTAssertEqual(Alerts.splitTopicURL("https://ntfy.example.com/ntfy").map { [$0.0.absoluteString, $0.1] }, ["https://ntfy.example.com", "ntfy"])
        XCTAssertEqual(Alerts.splitTopicURL("https://host:8443/push/my-topic").map { [$0.0.absoluteString, $0.1] }, ["https://host:8443/push", "my-topic"])
        XCTAssertNil(Alerts.splitTopicURL("https://ntfy.sh/"))
    }

    func testUsageWithoutAResetTimeComesBackAfterTheCooldown() throws {
        let (_, env) = setup { $0.alerts.set(AlertSettings.everyProfile, .usageCritical, mac: true, activeOnly: false) }
        try LimitStore.write(ProfileLimits(fiveHour: LimitWindow(usedPercentage: 99, resetsAt: nil), sevenDay: nil, sampledAt: now), profile: "a", env.paths)
        Alerts.usage("a", env: env, now: now)
        Alerts.usage("a", env: env, now: now + 60)
        XCTAssertEqual(Alerts.read(env.paths).count, 1)
        Alerts.usage("a", env: env, now: now + 3700)
        XCTAssertEqual(Alerts.read(env.paths).count, 2)
    }

    func testPanelMoveTheUserAskedForIsNotAnAlert() {
        let (_, env) = setup { $0.alerts.set(AlertSettings.everyProfile, .switched, mac: true) }
        Alerts.event(move("a", "b", source: "vscode", trigger: "now"), env: env, now: now)
        XCTAssertTrue(Alerts.read(env.paths).isEmpty)
        Alerts.event(move("a", "b", source: "vscode", trigger: "limit_stop"), env: env, now: now)
        XCTAssertEqual(Alerts.read(env.paths).count, 1)
    }

    func testTopicValidation() {
        XCTAssertTrue(Alerts.validTopic("my-alerts_1"))
        XCTAssertFalse(Alerts.validTopic("a/b"))
        XCTAssertFalse(Alerts.validTopic(""))
    }
}

final class SessionNameTests: XCTestCase {
    func testSnapshotNamesLiveSessionsFromTheirTranscript() throws {
        let box = Sandbox()
        let env = box.env()
        var c = HopperConfig()
        c.profiles = [Profile(name: "a", dir: box.home.appendingPathComponent(".claude").path, exportConfigDir: false)]
        try c.save(env.paths)
        let id = "aaaaaaaa-0000-4000-8000-000000000001"
        box.write(#"{"type":"user","message":{"content":"hi"}}"# + "\n" + #"{"type":"custom-title","customTitle":"fix-the-tests"}"# + "\n",
                  "home/.claude/projects/-x/\(id).jsonl")
        try FileIO.encode(SessionRecord(session: id, resume: id, pid: getpid(), child: 0, profile: "a", cwd: "/x", started: "t"), to: env.paths.session(id).record)
        XCTAssertEqual(HopperSnapshot.load(env.paths, home: box.home).names[id], "fix-the-tests")
    }
}
