import XCTest
@testable import SessionHopperCore

final class HookTests: XCTestCase {
    let sb = Sandbox()
    let sid = "11111111-1111-1111-1111-111111111111"
    var env: HopperEnvironment { sb.env(["SESSIONHOPPER_SESSION_ID": sid, "SESSIONHOPPER_PROFILE": "work"]) }
    var f: SessionFiles { env.paths.session(sid) }

    @discardableResult
    func hook(_ body: String, installed: String? = nil, env e: HopperEnvironment? = nil) -> String? {
        HookHandler.handle(input: Data(body.utf8), env: e ?? env, installedProfile: installed)
    }

    func ev(_ name: String, _ extra: String = "") -> String {
        #"{"hook_event_name":"\#(name)","session_id":"\#(sid)"\#(extra)}"#
    }

    func testTurnStateFollowsPromptAndStop() {
        hook(ev("UserPromptSubmit"))
        XCTAssertTrue(FileIO.exists(f.busy))
        hook(ev("Stop", #","background_tasks":[{"id":"b9","type":"shell","status":"running","command":"npm   test"},{"id":"x","status":"completed"}]"#))
        XCTAssertFalse(FileIO.exists(f.busy))
        XCTAssertEqual(FileIO.readString(f.jobs), "shell b9 - npm test\n")
        hook(ev("Stop", #","background_tasks":[]"#))
        XCTAssertFalse(FileIO.exists(f.jobs))
    }

    func testRateLimitStopFailure() {
        hook(ev("UserPromptSubmit"))
        hook(ev("StopFailure", #","error":"rate_limit","error_details":"429 Too Many Requests""#))
        XCTAssertFalse(FileIO.exists(f.busy), "the turn is over")
        XCTAssertTrue(FileIO.exists(f.interrupted))
        XCTAssertEqual(FileIO.readString(f.limited), "429 Too Many Requests")
    }

    func testOtherFailureIsNotALimit() {
        hook(ev("StopFailure", #","error":"overloaded""#))
        XCTAssertFalse(FileIO.exists(f.limited))
        hook(ev("StopFailure", #","error_type":"rate_limit""#))
        XCTAssertFalse(FileIO.exists(f.limited), "the documented field is `error`, not `error_type`")
    }

    func testPendingMoveNoticeOnce() throws {
        XCTAssertNil(hook(ev("UserPromptSubmit")), "nothing to say without a pending move")
        try FileIO.encode(PendingMove(to: "personal", trigger: "confirm", source: "cli"), to: f.pending)
        let out = json(hook(ev("PostToolUse")))
        XCTAssertEqual((out?["hookSpecificOutput"] as? [String: Any])?["additionalContext"] as? String, HookHandler.agentNotice)
        XCTAssertTrue((out?["systemMessage"] as? String)?.contains("moves to personal") ?? false)
        XCTAssertNil(hook(ev("PostToolUse")), "once")
    }

    func testSuggestionShownToUserOnce() throws {
        try FileIO.encode(Suggestion(from: "work", to: "personal", percent: 88, reason: "threshold"), to: f.suggest)
        let msg = json(hook(ev("UserPromptSubmit")))?["systemMessage"] as? String
        XCTAssertTrue(msg?.contains("work is near its usage limit (88%). personal has room.") ?? false, msg ?? "nil")
        XCTAssertNil(json(hook(ev("UserPromptSubmit")))?["hookSpecificOutput"], "the agent is not told about a mere suggestion")
        XCTAssertNil(hook(ev("PostToolUse")))
    }

    func testOtherConversationIgnoredAndClearFollowed() {
        let other = "22222222-2222-2222-2222-222222222222"
        hook(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(other)"}"#)
        XCTAssertFalse(FileIO.exists(f.busy), "a nested claude that inherited the env is not ours")
        hook(#"{"hook_event_name":"SessionStart","source":"clear","session_id":"\#(other)"}"#)
        XCTAssertEqual(FileIO.readString(f.current), other)
        hook(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(other)"}"#)
        XCTAssertTrue(FileIO.exists(f.busy), "after /clear the new id is the conversation")
    }

    func testInstalledHookLogsLimitOnlyWhenUnsupervised() {
        let plain = sb.env()
        hook(ev("StopFailure", #","error":"rate_limit""#), installed: "work", env: plain)
        XCTAssertEqual(EventLog.read(plain.paths).map(\.type), ["limit"])
        XCTAssertEqual(EventLog.read(plain.paths).first?.from, "work")
        hook(ev("UserPromptSubmit"), installed: "work", env: plain)
        XCTAssertFalse(FileIO.exists(f.busy))
        // Supervised session on a profile with installed hooks: the injected copy does the work.
        hook(ev("UserPromptSubmit"), installed: "work")
        XCTAssertFalse(FileIO.exists(f.busy))
        hook(ev("StopFailure", #","error":"rate_limit""#), installed: "work")
        XCTAssertEqual(EventLog.read(plain.paths).count, 1)
    }

    func testGarbageInputIsHarmless() {
        XCTAssertNil(hook("not json"))
        XCTAssertNil(hook("{}"))
    }
}

final class StatusLineTests: XCTestCase {
    let sb = Sandbox()
    let input = #"{"session_id":"s","model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":42.4,"resets_at":4102444800},"seven_day":{"used_percentage":61,"resets_at":4102444800}}}"#

    func testRecordsLimitsAndPrintsDefault() {
        let env = sb.env(["SESSIONHOPPER_PROFILE": "work"])
        let out = StatusLineBridge.run(input: Data(input.utf8), env: env, installedProfile: nil)
        XCTAssertEqual(out, "work · 5h 42% · 7d 61%\n")
        XCTAssertEqual(LimitStore.read("work", env.paths)?.fiveHour?.usedPercentage, 42.4)
    }

    func testChainsUserCommandWithSameStdin() {
        let seen = sb.root.appendingPathComponent("seen.json").path
        let env = sb.env(["SESSIONHOPPER_PROFILE": "work", "SESSIONHOPPER_USER_STATUSLINE": "cat > '\(seen)'; echo mine"])
        XCTAssertEqual(StatusLineBridge.run(input: Data(input.utf8), env: env, installedProfile: nil), "mine\n")
        XCTAssertEqual(try String(contentsOfFile: seen, encoding: .utf8), input)
    }

    func testSlowUserCommandTimesOut() {
        let env = sb.env(["SESSIONHOPPER_USER_STATUSLINE": "sleep 30"])
        let t = Date()
        _ = Shell.run("sleep 30", timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(t), 5)
        _ = env
    }

    func testNoRateLimitsLeavesSampleAlone() throws {
        let env = sb.env(["SESSIONHOPPER_PROFILE": "work"])
        try LimitStore.write(limits(50), profile: "work", env.paths)
        _ = StatusLineBridge.run(input: Data(#"{"model":{}}"#.utf8), env: env, installedProfile: nil)
        XCTAssertEqual(LimitStore.read("work", env.paths)?.fiveHour?.usedPercentage, 50)
    }

    func testInstalledModeUsesSavedStatusLine() throws {
        let env = sb.env()
        try FileIO.write(#"{"type":"command","command":"echo saved"}"#, to: env.paths.savedStatusLine("p1"))
        XCTAssertEqual(StatusLineBridge.run(input: Data(input.utf8), env: env, installedProfile: "p1"), "saved\n")
        XCTAssertNotNil(LimitStore.read("p1", env.paths))
    }

    func testEffectiveUserStatusLinePrecedence() throws {
        let dir = sb.profileDir(".claude-w", settings: #"{"statusLine":{"type":"command","command":"user-cmd","padding":2}}"#)
        let p = Profile(name: "w", dir: dir.path, exportConfigDir: true)
        let cwd = sb.root.appendingPathComponent("proj").path
        XCTAssertEqual(StatusLineBridge.effectiveUserStatusLine(cwd: cwd, profile: p, paths: sb.env().paths)?["command"] as? String, "user-cmd")
        sb.write(#"{"statusLine":{"type":"command","command":"local-cmd"}}"#, "proj/.claude/settings.local.json")
        XCTAssertEqual(StatusLineBridge.effectiveUserStatusLine(cwd: cwd, profile: p, paths: sb.env().paths)?["command"] as? String, "local-cmd")
    }
}
