import XCTest
@testable import SessionHopperCore

final class OneShotTests: XCTestCase {
    let now = 1_793_700_000.0 // Tue 2026-11-03 10:00 UTC

    func testPrepareSwapsTheOutputFormat() {
        let text = OneShot.prepare(["--model", "opus", "--session-id", "x"])
        XCTAssertEqual(text.format, .text)
        XCTAssertEqual(text.args, ["-p", "--model", "opus", "--session-id", "x", "--output-format", "stream-json", "--verbose"])
        let json = OneShot.prepare(["-p", "--output-format", "json"])
        XCTAssertEqual(json.format, .json)
        XCTAssertEqual(json.args, ["-p", "--output-format", "stream-json", "--verbose"])
        let stream = OneShot.prepare(["-p", "--output-format=stream-json", "--verbose"])
        XCTAssertEqual(stream.format, .streamJSON)
        XCTAssertEqual(stream.args, ["-p", "--verbose", "--output-format", "stream-json"])
    }

    func testRateLimitEventBecomesProfileLimits() {
        var a = OneShot.Attempt()
        a.read(line: #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1793715000,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":0.16,"resetsAt":1793715000,"status":"allowed"},"seven_day":{"utilization":0.03,"resetsAt":1794204000,"status":"allowed"}}}}"#, now: now)
        a.read(line: #"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#, now: now)
        XCTAssertEqual(a.limits?.fiveHour, LimitWindow(usedPercentage: 16, resetsAt: 1_793_715_000))
        XCTAssertEqual(a.limits?.sevenDay?.resetsAt, 1_794_204_000)
        XCTAssertEqual(a.resultText, "ok")
        XCTAssertEqual(OneShot.classify(a, now: now), .none)
    }

    func testRejectedEventIsALimit() {
        var a = OneShot.Attempt()
        a.read(line: #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1794204000,"rateLimitType":"seven_day"}}"#, now: now)
        XCTAssertEqual(OneShot.classify(a, now: now), .limit(until: 1_794_204_000, weekly: true))
    }

    func testFailureText() {
        func failing(_ text: String) -> OneShot.Failure {
            var a = OneShot.Attempt()
            a.read(line: "{\"type\":\"result\",\"is_error\":true,\"result\":\(String(data: try! JSONSerialization.data(withJSONObject: [text], options: .fragmentsAllowed), encoding: .utf8)!.dropFirst().dropLast())}", now: now)
            a.exit = 1
            return OneShot.classify(a, now: now)
        }
        XCTAssertEqual(failing("You've hit your weekly limit · resets Nov 3, 8pm (UTC)"), .limit(until: 1_793_736_000, weekly: true))
        XCTAssertEqual(failing("Claude AI usage limit reached|1793715000"), .limit(until: 1_793_715_000, weekly: false))
        XCTAssertEqual(failing("API Error: 402 This request requires more credits, or fewer max_tokens"), .credits)
        XCTAssertEqual(failing("OAuth access token is invalid"), .login)
        XCTAssertEqual(failing("Not logged in · Please run /login"), .login)
        XCTAssertEqual(failing("Error: tool crashed"), .other)
        var ok = OneShot.Attempt()
        ok.read(line: #"{"type":"result","is_error":false,"result":"the docs say usage limit is 5"}"#, now: now)
        XCTAssertEqual(OneShot.classify(ok, now: now), .none, "a successful answer that mentions limits is not a failure")
    }

    func testResetTextParsing() {
        XCTAssertEqual(OneShot.resetEpoch("resets 3:30am (utc)", now: now), 1_793_763_000) // tomorrow 03:30
        XCTAssertEqual(OneShot.resetEpoch("resets 8pm (utc)", now: now), 1_793_736_000) // today 20:00
        XCTAssertEqual(OneShot.resetEpoch("resets jan 2, 12am (utc)", now: now), 1_798_848_000) // next year
        XCTAssertNil(OneShot.resetEpoch("resets 8pm (europe/london)", now: now))
        XCTAssertEqual(OneShot.resetEpoch("limit reached|1793715000000", now: now), 1_793_715_000)
    }

    func testRetryResumesOnlyAnExistingTranscript() throws {
        let box = Sandbox()
        let projects = box.root.appendingPathComponent("projects")
        let args = ["-p", "--session-id", "8a1f1d3c-0000-4000-8000-000000000001"]
        XCTAssertEqual(OneShot.retryArgs(args, projects: projects), args)
        box.write("{}", "projects/-w/8a1f1d3c-0000-4000-8000-000000000001.jsonl")
        XCTAssertEqual(OneShot.retryArgs(args, projects: projects), ["-p", "--resume", "8a1f1d3c-0000-4000-8000-000000000001"])
        XCTAssertEqual(OneShot.retryArgs(["-p", "--session-id=8a1f1d3c-0000-4000-8000-000000000001"], projects: projects),
                       ["-p", "--resume", "8a1f1d3c-0000-4000-8000-000000000001"])
    }
}
