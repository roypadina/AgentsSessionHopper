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
        XCTAssertTrue(r.stderr.contains("session summary"), r.stderr)
        XCTAssertTrue(r.stderr.contains("status    ended, last turn finished (exit 3) · on default"), r.stderr)
        XCTAssertTrue(r.stderr.contains("resume    sessionhopper --resume \(h.sessionID(fromLaunch: first) ?? "?")"), r.stderr)
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

    /// 2026-10-25: a move ended a session mid-reply because the busy flag was gone. The transcript now has a say.
    func testAutoMoveWaitsForTheReplyEvenWhenHooksMissTheTurn() throws {
        try h.config { $0.autoMove = true }
        try h.scenario("""
            if [ "$N" = 1 ]; then
              P="$T/home/.claude/projects/-w"; mkdir -p "$P"
              printf '%s\\n' '{"type":"user","message":{"content":"go"}}' '{"type":"assistant","message":{"stop_reason":"tool_use","content":[]}}' \\
                '{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}' > "$P/$SID.jsonl"
              usage 90
              sleep 1.5
              touch "$T/alive-mid-turn"
              printf '%s\\n' '{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}' >> "$P/$SID.jsonl"
              sleep 5
            else exit 0; fi
            """)
        try h.run([])
        XCTAssertNotNil(h.read("alive-mid-turn"), "no move while the transcript shows the reply still coming")
        XCTAssertEqual(h.launches.count, 2)
        XCTAssertFalse(h.launches[1].contains("[sessionhopper]"), "the reply landed: resume silently")
    }

    func testCutOffShownByTheTranscriptResumesWithTheUsersOwnPrompt() throws {
        try h.config { $0.continuePrompt = "Custom {from}->{to}. {reason}" }
        try h.scenario("""
            if [ "$N" = 1 ]; then
              P="$T/home/.claude/projects/-w"; mkdir -p "$P"
              printf '%s\\n' '{"type":"user","message":{"content":"go"}}' '{"type":"assistant","message":{"stop_reason":"tool_use","content":[]}}' \\
                '{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}' > "$P/$SID.jsonl"
              usage 50
              "$SESSIONHOPPER_BIN" switch work --now > /dev/null
              sleep 5
            else exit 0; fi
            """)
        try h.run([])
        XCTAssertEqual(h.launches.count, 2)
        XCTAssertTrue(h.launches[1].contains("[sessionhopper] Custom default->work. This conversation was moved"), h.launches[1])
    }

    func testParkBeforePaidUsageAtTurnEnd() throws {
        try h.config { $0.waitForReset = false }
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
              [ -f "$SESSIONHOPPER_STATE_DIR/sessions/$SID.suggest" ] && cp "$SESSIONHOPPER_STATE_DIR/sessions/$SID.suggest" "$T/asked"
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
        XCTAssertEqual(FileIO.decode(Suggestion.self, from: h.t.appendingPathComponent("asked"))?.detail, "429 Too Many Requests", "the suggestion names the limit")
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

    /// 2026-10-26: a move landed on a profile whose login had expired; the session sat dead on "Login expired".
    func testLoginFailureMovesOnWhenOptedIn() throws {
        try h.config { $0.autoMove = true }
        try h.scenario("""
            if [ "$N" = 1 ]; then
              emit UserPromptSubmit
              emit StopFailure ',"error":"authentication_failed"'
              sleep 5
            else exit 0; fi
            """)
        try h.run([])
        XCTAssertEqual(h.launches.count, 2)
        XCTAssertEqual(h.events().map(\.type), ["login", "switch"])
        XCTAssertEqual(h.events().last?.trigger, "login_stop")
        XCTAssertTrue(h.launches[1].contains("login expired"), h.launches[1])
    }

    func testLoginFailureAsksByDefault() throws {
        try h.scenario("""
            emit UserPromptSubmit
            emit StopFailure ',"error":"authentication_failed"'
            sleep 1
            [ -f "$SESSIONHOPPER_STATE_DIR/sessions/$SID.suggest" ] && grep -q '"login"' "$SESSIONHOPPER_STATE_DIR/sessions/$SID.suggest" && touch "$T/asked"
            exit 0
            """)
        try h.run([])
        XCTAssertNotNil(h.read("asked"), "confirm-first: a login failure asks, it does not move by itself")
        XCTAssertEqual(h.launches.count, 1)
    }

    /// 2026-10-26: `switch claude1` landed on claude1 (over the suggest threshold) and auto-move undid it a second later.
    func testExplicitTargetIsNotUndoneByAutoMove() throws {
        try h.config { $0.autoMove = true }
        try LimitStore.write(ProfileLimits(fiveHour: LimitWindow(usedPercentage: 90, resetsAt: 4102444800), sevenDay: nil, sampledAt: 0),
                             profile: "work", h.env.paths)
        try h.scenario("""
            if [ "$N" = 1 ]; then
              usage 10
              "$SESSIONHOPPER_BIN" switch work --now > /dev/null
              sleep 5
            elif [ "$N" = 2 ]; then
              usage 90
              sleep 2
              exit 0
            else exit 0; fi
            """)
        try h.run([])
        XCTAssertEqual(h.launches.count, 2, "no automatic move away from the profile the user chose")
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
        try h.config { $0.waitForReset = false }
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

    func testMoveNowAtHardCutsInMidTurn() throws {
        try h.config { $0.autoMove = true; $0.moveNowAtHard = true }
        try h.scenario("""
            if [ "$N" = 1 ]; then
              emit UserPromptSubmit
              usage 98
              sleep 5
              touch "$T/turn-finished"
            else exit 0; fi
            """)
        try h.run(["first prompt"])
        XCTAssertNil(h.read("turn-finished"), "moved mid-turn, not at the turn end")
        XCTAssertEqual(h.launches.count, 2)
        XCTAssertTrue(h.launches[1].hasPrefix(h.workDir.path), h.launches[1])
        XCTAssertTrue(h.launches[1].contains("restarted Claude Code in the middle of your work"))
        XCTAssertEqual(h.events().last?.trigger, "hard")
    }

    func testParkNowAtHardWhenNothingHasRoom() throws {
        try h.config { $0.moveNowAtHard = true; $0.waitForReset = false }
        try h.scenario("""
            emit UserPromptSubmit
            usage 98
            sleep 5
            touch "$T/turn-finished"
            """)
        let r = try h.run(["--only", "default"])
        XCTAssertEqual(r.code, 2)
        XCTAssertNil(h.read("turn-finished"), "parked mid-turn")
        XCTAssertEqual(h.events().last?.type, "park")
    }

    func testFullAtLaunchWaitsForTheResetThenStarts() throws {
        try LimitStore.write(ProfileLimits(fiveHour: LimitWindow(usedPercentage: 99, resetsAt: FileIO.now() + 1), sevenDay: nil, sampledAt: 0),
                             profile: "default", h.env.paths)
        try h.scenario("exit 0")
        let r = try h.run(["--only", "default"], extraEnv: ["SESSIONHOPPER_RESET_SLACK": "0"])
        XCTAssertEqual(r.code, 0, r.stderr)
        XCTAssertTrue(r.stderr.contains("waiting for a reset: continues on default"), r.stderr)
        XCTAssertEqual(h.launches.count, 1, "started once the window reset")
        XCTAssertEqual(h.events().last?.type, "park")
        XCTAssertEqual(h.events().last?.to, "default")
    }

    func testAllFullMidSessionWaitsAndMovesWhereRoomComesBackWhenOptedIn() throws {
        try h.config { $0.autoMove = true }
        try LimitStore.write(ProfileLimits(fiveHour: LimitWindow(usedPercentage: 99, resetsAt: FileIO.now() + 3), sevenDay: nil, sampledAt: 0),
                             profile: "work", h.env.paths)
        try h.scenario("""
            if [ "$N" = 1 ]; then usage 98; sleep 10; else exit 0; fi
            """)
        let r = try h.run([], extraEnv: ["SESSIONHOPPER_RESET_SLACK": "0"])
        XCTAssertEqual(r.code, 0, r.stderr)
        XCTAssertEqual(h.launches.count, 2)
        XCTAssertTrue(h.launches[1].hasPrefix(h.workDir.path), h.launches[1])
        XCTAssertEqual(h.events().map(\.type), ["park", "switch"])
        XCTAssertEqual(h.events().last?.trigger, "wait")
    }

    func testWaitStaysOnItsProfileWithoutConsentButTakesAConfirmedMove() throws {
        try LimitStore.write(ProfileLimits(fiveHour: LimitWindow(usedPercentage: 10, resetsAt: 4102444800), sevenDay: nil, sampledAt: 0),
                             profile: "work", h.env.paths)
        try h.scenario("""
            if [ "$N" = 1 ]; then usage 98; sleep 10; else exit 0; fi
            """)
        var waitedOnOwnProfile = false
        let r = try h.run([], onStart: { _ in
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline, !self.h.events().contains(where: { $0.type == "park" }) { Thread.sleep(forTimeInterval: 0.1) }
            Thread.sleep(forTimeInterval: 1)
            // work has room, but moving there needs the user's OK: it waits for its own profile.
            waitedOnOwnProfile = self.h.launches.count == 1 && self.h.events().last?.to == "default"
            let sid = self.h.sessionID(fromLaunch: self.h.launches[0])!
            XCTAssertEqual(try? self.h.run(["switch", "work", "--session", sid]).code, 0)
        })
        XCTAssertEqual(r.code, 0, r.stderr)
        XCTAssertTrue(waitedOnOwnProfile, r.stderr)
        XCTAssertEqual(h.launches.count, 2)
        XCTAssertTrue(h.launches[1].hasPrefix(h.workDir.path), h.launches[1])
        XCTAssertEqual(h.events().last?.trigger, "confirm")
    }

    func testMoveSkipsAProfileWhoseLoginIsDead() throws {
        let spare = h.home.appendingPathComponent(".claude-spare")
        try FileManager.default.createDirectory(at: spare, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: spare.appendingPathComponent("projects"), withDestinationURL: h.defaultDir.appendingPathComponent("projects"))
        try h.run(["profiles", "import"])
        FileManager.default.createFile(atPath: h.workDir.appendingPathComponent("logged-out").path, contents: nil)
        try h.config { $0.autoMove = true }
        try h.scenario("""
            if [ "$N" = 1 ]; then usage 90; sleep 10; else exit 0; fi
            """)
        let r = try h.run([])
        XCTAssertEqual(h.launches.count, 2)
        XCTAssertTrue(h.launches[1].hasPrefix(spare.path), h.launches[1])
        XCTAssertTrue(r.stderr.contains("work: not logged in"), r.stderr)
        XCTAssertEqual(h.events().last?.detail, "skipped work: not logged in")
    }

    func testMoveBeforeTheFirstPromptStartsTheSameSessionAgain() throws {
        try h.write("", "no-transcript")
        try h.scenario("""
            if [ "$N" = 1 ]; then "$SESSIONHOPPER_BIN" switch work --now > /dev/null; sleep 5; else exit 0; fi
            """)
        XCTAssertEqual(try h.run([]).code, 0)
        XCTAssertEqual(h.launches.count, 2)
        let id = h.sessionID(fromLaunch: h.launches[0])!
        XCTAssertTrue(h.launches[1].hasPrefix(h.workDir.path + " --session-id \(id) "), "nothing to --resume yet: \(h.launches[1])")
    }

    func testHeldSessionIsNotCutInAtHard() throws {
        try h.config { $0.autoMove = true; $0.moveNowAtHard = true }
        try h.scenario("""
            "$SESSIONHOPPER_BIN" hold on > /dev/null
            emit UserPromptSubmit
            usage 99
            sleep 1.2
            exit 0
            """)
        XCTAssertEqual(try h.run([]).code, 0)
        XCTAssertEqual(h.launches.count, 1)
    }

    func testStartSaysWhichProfilesWereSkipped() throws {
        try LimitStore.write(ProfileLimits(fiveHour: LimitWindow(usedPercentage: 98, resetsAt: 4102444800), sevenDay: nil, sampledAt: 0),
                             profile: "default", h.env.paths)
        try h.scenario("exit 0")
        let r = try h.run([])
        XCTAssertTrue(r.stderr.contains("starting on work"), r.stderr)
        XCTAssertTrue(r.stderr.contains("skipped default 5h 98% · resets "), r.stderr)
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
