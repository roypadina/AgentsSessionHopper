import XCTest
@testable import SessionHopperCore

/// `sessionhopper <claude> <flags>`: how the VS Code extension calls `claudeCode.claudeProcessWrapper`.
/// The fake `claude` plays a panel process: stream-json in and out, answers `initialize`, echoes user messages
/// (`--replay-user-messages`), and answers each one per `behave-<default|work>` (ok | limit).
final class PanelTests: XCTestCase {
    var h: Harness!
    var claude: String { h.t.appendingPathComponent("claude").path }
    let flags = ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json", "--replay-user-messages"]
    let sid = "5b0c7f2e-0000-4000-8000-00000000beef"
    let initialize = #"{"type":"control_request","request_id":"init-1","request":{"subtype":"initialize"}}"#
    let hello = #"{"type":"user","message":{"role":"user","content":"hello"}}"#

    override func setUpWithError() throws {
        h = try Harness()
        try h.scenario(#"""
            who=default; [ -n "$CLAUDE_CONFIG_DIR" ] && who=work
            echo "$who $CLAUDE_CODE_ENTRYPOINT ${SID:-new}" >> "$T/panel-env"
            S=${SID:-5b0c7f2e-0000-4000-8000-00000000beef}
            mkdir -p "$T/home/.claude/projects/-w" && touch "$T/home/.claude/projects/-w/$S.jsonl"
            echo "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$S\"}"
            while IFS= read -r line; do
              echo "$who $line" >> "$T/panel-in"
              case "$line" in
                *'"subtype":"initialize"'*)
                  id=$(printf '%s' "$line" | sed 's/.*"request_id":"\([^"]*\)".*/\1/')
                  echo "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$id\"}}";;
                *'"type":"user"'*)
                  echo "$line"
                  case "$(cat "$T/behave-$who" 2>/dev/null || echo ok)" in
                    ok) echo '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.4,"resetsAt":4102444800}}}}'
                        echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"panel answer from $who\"}";;
                    limit) echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour","resetsAt":4102444800}}'
                        echo '{"type":"assistant","message":{"content":[{"type":"text","text":"You have hit your session limit"}]}}'
                        echo '{"type":"result","subtype":"success","is_error":true,"result":"You have hit your session limit"}';;
                  esac;;
              esac
            done
            exit 0
            """#)
    }

    override func tearDown() { h.cleanup() }

    func count(_ s: String, _ needle: String) -> Int { s.components(separatedBy: needle).count - 1 }

    func testPassesTheStreamThroughAndRecordsUsage() throws {
        let r = try h.run([claude] + flags, extraEnv: ["CLAUDE_CODE_ENTRYPOINT": "claude-vscode"], stdin: initialize + "\n" + hello + "\n")
        XCTAssertEqual(r.code, 0, r.stderr)
        XCTAssertTrue(r.stdout.hasPrefix(#"{"type":"system","subtype":"init""#), r.stdout)
        XCTAssertTrue(r.stdout.contains(#""request_id":"init-1""#), "the extension's own request is answered")
        XCTAssertTrue(r.stdout.hasSuffix("\"panel answer from default\"}\n"), r.stdout)
        XCTAssertEqual(h.read("panel-env"), "default claude-vscode new\n", "the extension's own variables survive")
        XCTAssertEqual(LimitStore.read("default", h.env.paths)?.fiveHour?.usedPercentage, 40)
        XCTAssertEqual(h.events().last.map { [$0.type, $0.to, $0.source] }, ["run", "default", "vscode"])
        XCTAssertNil(Sessions.find(sid, h.env.paths), "the session record goes when the panel closes")
    }

    func testALimitMovesTheConversationAndRedoesTheTurnWithoutThePanelNoticing() throws {
        try h.write("limit", "behave-default")
        let r = try h.run([claude] + flags, stdin: initialize + "\n" + hello + "\n")
        XCTAssertEqual(r.code, 0, r.stderr)
        XCTAssertTrue(r.stdout.contains("panel answer from work"), r.stdout)
        XCTAssertFalse(r.stdout.contains("session limit"), "the failed turn never reaches the panel")
        XCTAssertFalse(r.stdout.contains("rejected"))
        XCTAssertEqual(count(r.stdout, #""subtype":"init""#), 1, "the new claude's init is swallowed")
        XCTAssertEqual(count(r.stdout, "init-1"), 1, "the replayed initialize's answer is swallowed")
        XCTAssertEqual(count(r.stdout, "\"content\":\"hello\""), 1, "the replayed message's echo is swallowed")
        XCTAssertEqual(h.read("panel-in")?.split(separator: "\n").filter { $0.hasPrefix("work ") }.count, 2,
                       "work got the extension's initialize and the same message again")
        XCTAssertTrue(h.launches.last?.contains("--resume \(sid)") == true, h.launches.joined(separator: "\n"))
        XCTAssertEqual(h.events().last.map { [$0.type, $0.from, $0.to, $0.trigger] }, ["switch", "default", "work", "limit"])
        XCTAssertTrue(r.stderr.contains("moved this conversation from default to work (limit)"), r.stderr)
    }

    func testAConfirmedSwitchMovesAtTheTurnEnd() throws {
        try FileIO.encode(PendingMove(to: "work", trigger: "confirm", source: "cli"), to: h.env.paths.session(sid).pending)
        let r = try h.run([claude] + flags, stdin: initialize + "\n" + hello + "\n")
        XCTAssertTrue(r.stdout.contains("panel answer from default"), r.stdout)
        XCTAssertEqual(h.events().last.map { [$0.type, $0.from, $0.to, $0.trigger] }, ["switch", "default", "work", "confirm"])
        XCTAssertEqual(h.read("panel-in")?.split(separator: "\n").filter { $0.hasPrefix("work ") }, ["work " + initialize],
                       "an idle move replays only the startup request")
    }

    func testOtherCallsRunOnTheChosenProfile() throws {
        try FileIO.encode(ProfileLimits(fiveHour: LimitWindow(usedPercentage: 99, resetsAt: 4_102_444_800), sevenDay: nil,
                                        sampledAt: Date().timeIntervalSince1970), to: h.env.paths.limits("default"))
        _ = try h.run([claude, "auth", "status", "--json"])
        XCTAssertTrue((h.read("auths") ?? "").contains(h.workDir.path), h.read("auths") ?? "")
    }
}
