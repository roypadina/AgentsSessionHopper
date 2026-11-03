import XCTest
@testable import SessionHopperCore

/// `sessionhopper <claude> <flags>`: how the VS Code extension calls `claudeCode.claudeProcessWrapper`.
/// The fake `claude` plays a long-lived stream-json panel process; `behave-<default|work>` = ok | limit.
final class PanelTests: XCTestCase {
    var h: Harness!
    var claude: String { h.t.appendingPathComponent("claude").path }
    let flags = ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json"]

    override func setUpWithError() throws {
        h = try Harness()
        try h.scenario(#"""
            who=default; [ -n "$CLAUDE_CONFIG_DIR" ] && who=work
            echo "$who $CLAUDE_CODE_ENTRYPOINT" >> "$T/panel-env"
            echo '{"type":"system","subtype":"init","session_id":"5b0c7f2e-0000-4000-8000-00000000beef"}'
            case "$(cat "$T/behave-$who" 2>/dev/null || echo ok)" in
              ok) echo '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.4,"resetsAt":4102444800}}}}'
                  echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"panel answer from $who\"}"; exit 0;;
              limit) echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour","resetsAt":4102444800}}'
                  echo '{"type":"result","subtype":"success","is_error":true,"result":"You have hit your session limit"}';;
            esac
            # A real panel claude stays alive waiting for the next message: the stub idles below until killed.
            """#)
    }

    override func tearDown() { h.cleanup() }

    func testPassesTheStreamThroughAndRecordsUsage() throws {
        let r = try h.run([claude] + flags, extraEnv: ["CLAUDE_CODE_ENTRYPOINT": "claude-vscode"])
        XCTAssertEqual(r.code, 0, r.stderr)
        XCTAssertTrue(r.stdout.hasPrefix(#"{"type":"system","subtype":"init""#), r.stdout)
        XCTAssertTrue(r.stdout.hasSuffix("\"panel answer from default\"}\n"), "output reaches the extension unchanged")
        XCTAssertEqual(h.read("panel-env"), "default claude-vscode\n", "the extension's own variables survive")
        XCTAssertEqual(LimitStore.read("default", h.env.paths)?.fiveHour?.usedPercentage, 40)
        XCTAssertEqual(h.events().last.map { [$0.type, $0.to, $0.source] }, ["run", "default", "vscode"])
    }

    func testALimitEndsThatClaudeAndTheReopenLandsOnTheNextProfile() throws {
        try h.write("limit", "behave-default")
        let r = try h.run([claude] + flags, timeout: 15)
        XCTAssertNotEqual(r.code, 0, "the stuck claude was ended")
        XCTAssertTrue(r.stderr.contains("default is out of usage: reopen this conversation to continue on work"), r.stderr)
        XCTAssertEqual(h.events().last.map { [$0.type, $0.from, $0.to] }, ["limit", "default", "work"])
        let again = try h.run([claude] + flags + ["--resume", "5b0c7f2e-0000-4000-8000-00000000beef"])
        XCTAssertTrue(again.stdout.contains("panel answer from work"), again.stdout)
    }

    func testOtherCallsRunOnTheChosenProfile() throws {
        try FileIO.encode(ProfileLimits(fiveHour: LimitWindow(usedPercentage: 99, resetsAt: 4_102_444_800), sevenDay: nil,
                                        sampledAt: Date().timeIntervalSince1970), to: h.env.paths.limits("default"))
        _ = try h.run([claude, "auth", "status", "--json"])
        XCTAssertTrue((h.read("auths") ?? "").contains(h.workDir.path), h.read("auths") ?? "")
    }
}
