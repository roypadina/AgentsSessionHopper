import XCTest
@testable import SessionHopperCore

/// `sessionhopper run`: the fake `claude` plays a `-p` run in stream-json. Per profile it reads
/// `behave-<default|work|gw>` (ok | limit | credits); `gw` = started with the gateway variables.
final class RunTests: XCTestCase {
    var h: Harness!
    let sid = "5b0c7f2e-0000-4000-8000-00000000abcd"

    override func setUpWithError() throws {
        h = try Harness()
        try h.scenario(#"""
            who=default; [ -n "$CLAUDE_CONFIG_DIR" ] && who=work; [ -n "$ANTHROPIC_BASE_URL" ] && who=gw
            echo "$who $ANTHROPIC_BASE_URL $ANTHROPIC_AUTH_TOKEN $ENABLE_TOOL_SEARCH" >> "$T/run-env"
            echo "$who ${CLAUDE_CODE_OAUTH_TOKEN:-none}" >> "$T/tokens"
            case "$(cat "$T/behave-$who" 2>/dev/null || echo ok)" in
              ok) echo '{"type":"system","subtype":"init"}'
                  echo '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.5,"resetsAt":4102444800}}}}'
                  echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"answer from $who\"}"; exit 0;;
              limit) echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour","resetsAt":4102444800}}'
                  echo '{"type":"result","subtype":"success","is_error":true,"result":"You have hit your session limit"}'; exit 1;;
              opus) echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"seven_day_opus","resetsAt":4102444800}}'
                  echo '{"type":"result","subtype":"success","is_error":true,"result":"You have hit your Opus limit"}'; exit 1;;
              credits) echo 'API Error: 402 This request requires more credits' >&2
                  echo '{"type":"result","subtype":"success","is_error":true,"result":"API Error: 402 This request requires more credits, or fewer max_tokens"}'; exit 1;;
            esac
            """#)
    }

    override func tearDown() { h.cleanup() }

    func addGateway() throws {
        let key = h.t.appendingPathComponent("or.key").path
        XCTAssertEqual(try h.run(["profiles", "add", "gw", "--openrouter", "--model", "opus=anthropic/claude-opus-5", "--key-file", key]).code, 0)
        try Gateway.writePrivate(Data("sk-or-test\n".utf8), to: URL(fileURLWithPath: key))
    }

    func testFirstProfileAnswersAndUsageIsRecorded() throws {
        let r = try h.run(["run", "--", "-p", "--session-id", sid, "--model", "opus"])
        XCTAssertEqual(r.code, 0, r.stderr)
        XCTAssertEqual(r.stdout, "answer from default\n")
        XCTAssertEqual(h.launches.count, 1)
        XCTAssertTrue(h.launches[0].contains("--output-format stream-json --verbose"))
        XCTAssertEqual(LimitStore.read("default", h.env.paths)?.fiveHour?.usedPercentage, 50)
    }

    func testLimitRetriesTheSameTurnOnTheNextProfile() throws {
        try h.write("limit", "behave-default")
        let r = try h.run(["run", "--", "-p", "--session-id", sid, "--output-format", "json"])
        XCTAssertEqual(r.code, 0, r.stderr)
        XCTAssertEqual(FileIO.jsonObject(Data(r.stdout.utf8))?["result"] as? String, "answer from work")
        XCTAssertEqual(h.launches.count, 2)
        XCTAssertTrue(h.launches[1].contains("--resume \(sid)"), "the retry continues the conversation the first attempt saved")
        XCTAssertEqual(LimitStore.read("default", h.env.paths)?.fiveHour?.usedPercentage, 100)
        XCTAssertEqual(h.events().map(\.type).suffix(2), ["limit", "run"])
        XCTAssertEqual(h.events().last?.to, "work")
        // Next run skips the full profile straight away.
        _ = try h.run(["run", "--", "-p", "--resume", sid])
        XCTAssertEqual(h.launches.count, 3)
        XCTAssertTrue(h.launches[2].hasPrefix(h.workDir.path))
    }

    func testGatewayIsTheLastFallbackAndAllFullExits75() throws {
        try addGateway()
        try h.write("limit", "behave-default")
        try h.write("limit", "behave-work")
        let r = try h.run(["run", "--", "-p", "--model", "opus"])
        XCTAssertEqual(r.code, 0, r.stderr)
        XCTAssertEqual(r.stdout, "answer from gw\n")
        XCTAssertTrue(h.launches[2].contains("--model anthropic/claude-opus-5"))
        XCTAssertEqual(h.read("run-env")?.split(separator: "\n").last, "gw https://openrouter.ai/api sk-or-test true")
        XCTAssertFalse(h.launches.joined().contains("sk-or-test"), "the key never goes on argv")

        try h.write("credits", "behave-gw")
        let all = try h.run(["run", "--", "-p"])
        XCTAssertEqual(all.code, OneShot.allFullExit)
        XCTAssertTrue(all.stderr.contains("no profile can take this run"), all.stderr)
        XCTAssertEqual(LimitStore.read("gw", h.env.paths)?.spendLimit?.usedPercentage, 100)
    }

    func testManualGatewayIsNeverPickedAndMockUsageForcesAMove() throws {
        try addGateway()
        XCTAssertEqual(try h.run(["config", "gateway", "manual"]).code, 0)
        let mock = h.t.appendingPathComponent("mock")
        try FileIO.encode(limits(99), to: mock.appendingPathComponent("default.limits.json"))
        let r = try h.run(["run", "--", "-p"], extraEnv: ["SESSIONHOPPER_MOCK_LIMITS": mock.path])
        XCTAssertEqual(r.stdout, "answer from work\n", "mocked 99% on default moves the run to work")
        try FileIO.encode(limits(99), to: mock.appendingPathComponent("work.limits.json"))
        let none = try h.run(["run", "--", "-p"], extraEnv: ["SESSIONHOPPER_MOCK_LIMITS": mock.path])
        XCTAssertEqual(none.code, OneShot.allFullExit, "manual: the gateway is not used on its own")
        XCTAssertEqual(try h.run(["run", "--only", "-P", "gw", "--", "-p"], extraEnv: ["SESSIONHOPPER_MOCK_LIMITS": mock.path]).stdout, "answer from gw\n")
    }

    func testCallerTokenStaysWithTheFirstProfileAndOnSwitchFires() throws {
        try addGateway()
        let hook = h.t.appendingPathComponent("hook.log").path
        XCTAssertEqual(try h.run(["config", "on-switch", "echo \"$SESSIONHOPPER_EVENT $SESSIONHOPPER_FROM>$SESSIONHOPPER_TO $SESSIONHOPPER_REASON\" >> '\(hook)'"]).code, 0)
        try h.write("limit", "behave-default")
        try h.write("limit", "behave-work")
        let r = try h.run(["run", "--", "-p"], extraEnv: ["CLAUDE_CODE_OAUTH_TOKEN": "caller-token"])
        XCTAssertEqual(r.stdout, "answer from gw\n", r.stderr)
        XCTAssertFalse(r.stderr.contains("\u{1B}["), "no colour codes when stderr is not a terminal")
        XCTAssertEqual(h.read("tokens"), "default caller-token\nwork none\ngw none\n",
                       "the caller's token is account 1's: never given to another Claude profile or to the gateway")
        let deadline = Date().addingTimeInterval(5)
        while (h.read("hook.log") ?? "").split(separator: "\n").count < 3 && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(Set((h.read("hook.log") ?? "").split(separator: "\n").map(String.init)),
                       ["limit default> limit", "limit work> limit", "run work>gw ok"])

        // A Claude profile's own stored token wins over the caller's.
        let tok = h.t.appendingPathComponent("work.token").path
        try h.config { c in c.profiles[1].keyFile = tok }
        try Gateway.writePrivate(Data("work-token\n".utf8), to: URL(fileURLWithPath: tok))
        try h.write("ok", "behave-work")
        FileIO.remove(h.env.paths.limits("work"))
        _ = try h.run(["run", "--", "-p"], extraEnv: ["CLAUDE_CODE_OAUTH_TOKEN": "caller-token"])
        XCTAssertEqual(h.read("tokens")?.split(separator: "\n").last, "work work-token")
    }

    func testRunStaysOnTheProfileThatServedTheLastTurnAmongEqualPriorities() throws {
        try h.write("limit", "behave-default")
        XCTAssertEqual(try h.run(["run", "--", "-p"]).stdout, "answer from work\n")
        // default has reset: same priority, so the run stays on work until work is full.
        FileIO.remove(h.env.paths.limits("default"))
        try h.write("ok", "behave-default")
        XCTAssertEqual(try h.run(["run", "--", "-p"]).stdout, "answer from work\n")
        // A better priority wins at once.
        XCTAssertEqual(try h.run(["profiles", "priority", "work", "2"]).code, 0)
        XCTAssertEqual(try h.run(["run", "--", "-p"]).stdout, "answer from default\n")
    }

    // MARK: a stream-json caller that keeps stdin open (it writes its message, then waits, pipe open, for the result)

    let streamArgs = ["run", "--", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
    let hello = #"{"type":"user","message":{"role":"user","content":"hi"}}"#

    /// Plays `claude --input-format stream-json`: answers the first line, then reads on until its stdin ends.
    func streamScenario() throws {
        try h.scenario(#"""
            who=default; [ -n "$CLAUDE_CONFIG_DIR" ] && who=work
            IFS= read -r line; echo "$line" >> "$T/got-$who"
            case "$(cat "$T/behave-$who" 2>/dev/null || echo ok)" in
              ok) echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"answer from $who\"}";;
              limit) echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour","resetsAt":4102444800}}'
                  echo '{"type":"result","subtype":"success","is_error":true,"result":"You have hit your session limit"}';;
            esac
            while IFS= read -r line; do echo "$line" >> "$T/got-$who"; done
            exit 0
            """#)
    }

    func waitFor(_ file: String, _ text: String) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while h.read(file) != text && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        return h.read(file) == text
    }

    func testStreamJSONCallerKeepingStdinOpenIsServedAtOnce() throws {
        try streamScenario()
        let input = Pipe()
        var served = false
        let r = try h.run(streamArgs, input: input, onStart: { _ in
            try? input.fileHandleForWriting.write(contentsOf: Data((self.hello + "\n").utf8))
            served = self.waitFor("got-default", self.hello + "\n")
            try? input.fileHandleForWriting.close()
        })
        XCTAssertTrue(served, "claude gets the message while the caller still holds stdin open (run used to read stdin to the end first)")
        XCTAssertEqual(r.code, 0, r.stderr)
        XCTAssertTrue(r.stdout.contains("answer from default"), r.stdout)
    }

    func testLimitRetryReplaysTheStreamAndKeepsItFlowing() throws {
        try streamScenario()
        try h.write("limit", "behave-default")
        let input = Pipe()
        let later = #"{"type":"control_request","request_id":"r2","request":{"subtype":"set_model","model":"haiku"}}"#
        var replayed = false, flowing = false
        let r = try h.run(streamArgs, input: input, onStart: { _ in
            try? input.fileHandleForWriting.write(contentsOf: Data((self.hello + "\n").utf8))
            replayed = self.waitFor("got-work", self.hello + "\n")
            try? input.fileHandleForWriting.write(contentsOf: Data((later + "\n").utf8))
            flowing = self.waitFor("got-work", self.hello + "\n" + later + "\n")
            try? input.fileHandleForWriting.close()
        })
        XCTAssertTrue(replayed, "the next profile gets the same turn while the caller's stdin is still open")
        XCTAssertTrue(flowing, "input that arrives after the retry goes to the new claude")
        XCTAssertEqual(h.read("got-default"), hello + "\n", "the failed claude's stdin was closed, so it ended")
        XCTAssertEqual(r.code, 0, r.stderr)
        XCTAssertTrue(r.stdout.contains("answer from work"), r.stdout)
        XCTAssertEqual(h.events().map(\.type).suffix(2), ["limit", "run"])
    }

    func testGatewayWithoutKeyIsSkipped() throws {
        XCTAssertEqual(try h.run(["profiles", "add", "gw", "--openrouter", "--key-file", h.t.appendingPathComponent("missing.key").path]).code, 0)
        try h.write("limit", "behave-default")
        try h.write("limit", "behave-work")
        let r = try h.run(["run", "--", "-p"])
        XCTAssertEqual(r.code, OneShot.allFullExit)
        XCTAssertTrue(r.stderr.contains("gw: no API key"), r.stderr)
        XCTAssertEqual(h.launches.count, 2, "never launched without its key (it would fall back to a Claude login)")
    }

    func testDelegateRunsOnAnotherProfileAndSkipsASpentModel() throws {
        // Called from a session on `default`: the task goes to `work`.
        var r = try h.run(["delegate", "--model", "fable", "summarise the repo"], extraEnv: ["SESSIONHOPPER_PROFILE": "default"])
        XCTAssertEqual(r.code, 0, r.stderr)
        XCTAssertEqual(r.stdout, "answer from work\n")
        XCTAssertTrue(h.launches.last?.contains("--model fable") == true)
        // work's own Opus/Fable limit: marked for the model only, the account keeps room.
        try h.write("opus", "behave-work")
        r = try h.run(["delegate", "--model", "fable", "again"], extraEnv: ["SESSIONHOPPER_PROFILE": "default"])
        XCTAssertNotEqual(r.code, 0)
        XCTAssertTrue(ModelLimits.isFull("work", model: "fable", h.env.paths, now: FileIO.now()))
        XCTAssertNil(LimitStore.read("work", h.env.paths)?.sevenDay, "the account-wide weekly window is not marked")
        r = try h.run(["delegate", "--model", "fable", "--here", "again"], extraEnv: ["SESSIONHOPPER_PROFILE": "default"])
        XCTAssertEqual(r.stdout, "answer from default\n", "--here allows this profile; work is skipped for fable")
        XCTAssertTrue(r.stderr.contains("fable is spent on work"), r.stderr)
        r = try h.run(["delegate", "--modle", "fable", "typo"], extraEnv: ["SESSIONHOPPER_PROFILE": "default"])
        XCTAssertNotEqual(r.code, 0)
        XCTAssertTrue(r.stderr.contains("unknown option --modle"), r.stderr)
    }

}

private func limits(_ five: Double) -> ProfileLimits {
    ProfileLimits(fiveHour: LimitWindow(usedPercentage: five, resetsAt: 4_102_444_800), sevenDay: nil, sampledAt: Date().timeIntervalSince1970)

}
