import XCTest
@testable import SessionHopperCore

final class HandOffTests: XCTestCase {
    var h: Harness!

    override func setUpWithError() throws { h = try Harness() }
    override func tearDown() { h.cleanup() }

    func testNewSessionStartsOnFirstProfileAndExitsWithClaudesCode() throws {
        try h.scenario("""
            emit SessionStart ',"source":"startup"'
            usage 10
            sleep 0.3
            exit 3
            """)
        let r = try h.run(["fix the tests"])
        XCTAssertEqual(r.code, 3)
        XCTAssertEqual(h.launches.count, 1)
        let first = h.launches[0]
        XCTAssertTrue(first.hasPrefix("<unset> --session-id "), "default profile keeps CLAUDE_CONFIG_DIR unset: \(first)")
        XCTAssertTrue(first.contains(#"--settings {"hooks":{"#))
        XCTAssertTrue(first.contains(#""statusLine":{"command":"#))
        XCTAssertTrue(first.hasSuffix("fix the tests"), "the first prompt goes to the first launch")
        XCTAssertNotNil(UUID(uuidString: h.sessionID(fromLaunch: first) ?? ""))
        XCTAssertEqual(LimitStore.read("default", h.env.paths)?.fiveHour?.usedPercentage, 10)
        XCTAssertTrue(Sessions.live(h.env.paths).isEmpty, "session record removed on exit")
        XCTAssertEqual(h.read("statusline-out"), "default · 5h 10%\n")
    }

    func testConfirmedMoveWaitsForTurnEnd() throws {
        try h.scenario("""
            if [ "$N" = 1 ]; then
              emit UserPromptSubmit
              usage 90
              sleep 0.6
              [ -f "$SESSIONHOPPER_STATE_DIR/sessions/$SID.suggest" ] && touch "$T/suggested"
              "$SESSIONHOPPER_BIN" switch > "$T/switch-out"
              emit PostToolUse
              sleep 0.8
              touch "$T/alive-before-stop"
              emit Stop ',"background_tasks":[]'
            else
              sleep 0.2; exit 0
            fi
            """)
        let r = try h.run(["--model", "opus", "first prompt"])
        XCTAssertEqual(r.code, 0, r.stderr)
        XCTAssertNotNil(h.read("suggested"), "85%+ with room elsewhere: suggest first")
        XCTAssertNotNil(h.read("alive-before-stop"), "no move while the turn runs")
        XCTAssertTrue(h.read("switch-out")?.contains("when this turn ends") ?? false)
        XCTAssertTrue(h.read("hook-out")?.contains(HookHandler.agentNotice.prefix(40)) ?? false, "the agent is told to wrap up")
        XCTAssertEqual(h.launches.count, 2)
        let (a, b) = (h.launches[0], h.launches[1])
        XCTAssertTrue(b.hasPrefix(h.workDir.path + " --resume "), b)
        XCTAssertEqual(h.sessionID(fromLaunch: a), h.sessionID(fromLaunch: b), "same conversation")
        XCTAssertFalse(b.contains("first prompt"), "the first prompt is not replayed")
        XCTAssertTrue(b.contains("--model opus"))
        XCTAssertFalse(b.contains("[sessionhopper]"), "an idle move resumes silently")
        let ev = h.events()
        XCTAssertEqual(ev.map(\.type), ["suggest", "switch"])
        XCTAssertEqual(ev.last?.from, "default")
        XCTAssertEqual(ev.last?.to, "work")
        XCTAssertEqual(ev.last?.trigger, "confirm")
        XCTAssertEqual(ev.last?.source, "cli")
        XCTAssertEqual(ev.last?.profiles?["default"]?.fiveHour, 90)
    }

    func testNoMoveWithoutConfirmationByDefault() throws {
        try h.scenario("""
            usage 90
            sleep 1.2
            exit 0
            """)
        try h.run([])
        XCTAssertEqual(h.launches.count, 1)
        XCTAssertEqual(h.events().map(\.type), ["suggest"])
    }

    func testMoveWithoutAskingIsOptIn() throws {
        try h.config { $0.autoMove = true }
        try h.scenario("""
            if [ "$N" = 1 ]; then usage 90; sleep 5; else exit 0; fi
            """)
        try h.run([])
        XCTAssertEqual(h.launches.count, 2)
        XCTAssertEqual(h.events().last?.trigger, "auto")
    }

    func testParkBeforePaidUsageAtTurnEnd() throws {
        try h.scenario("""
            emit UserPromptSubmit
            usage 98
            sleep 0.8
            touch "$T/alive-before-stop"
            emit Stop
            sleep 5
            """)
        let r = try h.run([])
        XCTAssertEqual(r.code, 2)
        XCTAssertNotNil(h.read("alive-before-stop"), "parks at the turn end, not mid-turn")
        XCTAssertEqual(h.launches.count, 1, "parking never moves the session")
        let sid = h.sessionID(fromLaunch: h.launches[0])!
        XCTAssertTrue(r.stderr.contains("sessionhopper --resume \(sid)"), r.stderr)
        XCTAssertEqual(h.events().last?.type, "park")
        XCTAssertEqual(h.events().last?.trigger, "park")
        XCTAssertTrue(h.read("hook-out")?.isEmpty ?? true)
    }

    func testHeldSessionIsNotParked() throws {
        try h.scenario("""
            "$SESSIONHOPPER_BIN" hold on > /dev/null
            usage 99
            sleep 1.2
            exit 0
            """)
        let r = try h.run([])
        XCTAssertEqual(r.code, 0)
        XCTAssertFalse(h.events().contains { $0.type == "park" })
    }

    func testLimitStopAsksThenResumesWorkOnConfirm() throws {
        try h.scenario("""
            if [ "$N" = 1 ]; then
              emit UserPromptSubmit
              usage 100
              emit StopFailure ',"error":"rate_limit","error_details":"429 Too Many Requests"'
              sleep 1
              [ -f "$SESSIONHOPPER_STATE_DIR/sessions/$SID.suggest" ] && touch "$T/asked"
              "$SESSIONHOPPER_BIN" switch work > /dev/null
              sleep 5
            else exit 0; fi
            """)
        try h.run([])
        XCTAssertNotNil(h.read("asked"), "a limit stop asks; it does not park or move by itself")
        XCTAssertEqual(h.launches.count, 2)
        XCTAssertTrue(h.launches[1].contains("stopped on a usage limit"), "resumes with a prompt to pick the work back up")
        XCTAssertEqual(h.events().map(\.type), ["limit", "suggest", "switch"])
        XCTAssertEqual(h.events().first?.detail, "429 Too Many Requests")
    }

    func testLimitStopMovesAtOnceWhenOptedIn() throws {
        try h.config { $0.autoMove = true }
        try h.scenario("""
            if [ "$N" = 1 ]; then
              emit UserPromptSubmit
              emit StopFailure ',"error":"rate_limit"'
              sleep 5
            else exit 0; fi
            """)
        try h.run([])
        XCTAssertEqual(h.launches.count, 2)
        XCTAssertEqual(h.events().last?.trigger, "limit_stop")
        XCTAssertTrue(h.launches[1].contains("stopped on a usage limit"))
    }

    func testSwitchNowCutsInAndListsRunningJobs() throws {
        try h.scenario("""
            if [ "$N" = 1 ]; then
              emit UserPromptSubmit
              emit Stop ',"background_tasks":[{"id":"b1","type":"shell","status":"running","command":"tail -f build.log"}]'
              "$SESSIONHOPPER_BIN" switch work --now > /dev/null
              sleep 5
            else exit 0; fi
            """)
        try h.run(["first prompt"])
        XCTAssertEqual(h.launches.count, 2)
        XCTAssertTrue(h.launches[1].contains("restarted Claude Code in the middle of your work"))
        XCTAssertTrue(h.launches[1].contains("- shell b1 - tail -f build.log"))
        XCTAssertEqual(h.events().last?.trigger, "now")
    }

    func testBackgroundJobsDelayAConfirmedMove() throws {
        try h.scenario("""
            if [ "$N" = 1 ]; then
              emit Stop ',"background_tasks":[{"id":"b1","type":"shell","status":"running"}]'
              "$SESSIONHOPPER_BIN" switch > /dev/null
              sleep 0.8
              touch "$T/alive-with-jobs"
              emit Stop ',"background_tasks":[]'
              sleep 5
            else exit 0; fi
            """)
        try h.run([])
        XCTAssertNotNil(h.read("alive-with-jobs"))
        XCTAssertEqual(h.launches.count, 2)
    }

    func testOnlyParksWithoutLaunchingWhenFull() throws {
        try LimitStore.write(ProfileLimits(fiveHour: LimitWindow(usedPercentage: 99, resetsAt: 4102444800), sevenDay: nil, sampledAt: 0),
                             profile: "default", h.env.paths)
        let r = try h.run(["--only", "default"])
        XCTAssertEqual(r.code, 2)
        XCTAssertTrue(h.launches.isEmpty)
        XCTAssertEqual(h.events().last?.type, "park")
        // Without --only the full profile is just skipped.
        try h.scenario("exit 0")
        try h.run([])
        XCTAssertTrue(h.launches[0].hasPrefix(h.workDir.path), h.launches[0])
    }

    func testSigtermIsForwardedToClaude() throws {
        try h.scenario("touch \"$T/started\"")
        let r = try h.run([]) { p in
            let deadline = Date().addingTimeInterval(10)
            while self.h.read("started") == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            kill(p.processIdentifier, SIGTERM)
        }
        XCTAssertEqual(r.code, 0, "the stub exits 0 on TERM and we pass its code on")
        let pid = Int32(h.read("pids")!.split(separator: "\n")[0])!
        XCTAssertNotEqual(kill(pid, 0), 0, "claude is gone too")
    }
}
