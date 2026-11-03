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
            case "$(cat "$T/behave-$who" 2>/dev/null || echo ok)" in
              ok) echo '{"type":"system","subtype":"init"}'
                  echo '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.5,"resetsAt":4102444800}}}}'
                  echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"answer from $who\"}"; exit 0;;
              limit) echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour","resetsAt":4102444800}}'
                  echo '{"type":"result","subtype":"success","is_error":true,"result":"You have hit your session limit"}'; exit 1;;
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

    func testGatewayWithoutKeyIsSkipped() throws {
        XCTAssertEqual(try h.run(["profiles", "add", "gw", "--openrouter", "--key-file", h.t.appendingPathComponent("missing.key").path]).code, 0)
        try h.write("limit", "behave-default")
        try h.write("limit", "behave-work")
        let r = try h.run(["run", "--", "-p"])
        XCTAssertEqual(r.code, OneShot.allFullExit)
        XCTAssertTrue(r.stderr.contains("gw: no API key"), r.stderr)
        XCTAssertEqual(h.launches.count, 2, "never launched without its key (it would fall back to a Claude login)")
    }
}

private func limits(_ five: Double) -> ProfileLimits {
    ProfileLimits(fiveHour: LimitWindow(usedPercentage: five, resetsAt: 4_102_444_800), sevenDay: nil, sampledAt: Date().timeIntervalSince1970)
}
