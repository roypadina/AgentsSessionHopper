import XCTest
@testable import SessionHopperCore

final class ShimTests: XCTestCase {
    var h: Harness!

    override func setUpWithError() throws { h = try Harness() }
    override func tearDown() { h.cleanup() }

    func testNonInteractiveCallsGoStraightToClaude() throws {
        let r = try h.run(["shim", "--version"])
        XCTAssertEqual(r.stdout, "9.9.9 (stub)\n")
        XCTAssertEqual(h.launches, ["<unset> --version"], "no --settings: not a supervised session")
        try h.run(["shim", "auth", "status"])
        XCTAssertEqual(h.read("auths"), "<unset> auth status\n")
    }

    func testClaudeStartedInsideASessionIsNotSupervisedAgain() throws {
        try h.scenario("exit 0")
        try h.run(["shim", "hello"], extraEnv: ["SESSIONHOPPER_SESSION_ID": "aaaaaaaa-0000-0000-0000-000000000009"])
        XCTAssertEqual(h.launches, ["<unset> hello"])
    }

    func testInteractiveLaunchIsSupervised() throws {
        try h.scenario("exit 0")
        try h.run(["shim", "hello"])
        XCTAssertTrue(h.launches[0].contains("--session-id"))
        XCTAssertTrue(h.launches[0].contains("--settings"))
    }

    func testLoginAndLogoutAreBlockedInASharedMcpSession() throws {
        let store = h.t.appendingPathComponent("mcp-store").path
        try h.config { $0.mcpStore = store }
        let shared = ["SESSIONHOPPER_SESSION_ID": "aaaaaaaa-0000-0000-0000-000000000009", McpShare.envVar: store]
        for args in [["auth", "logout"], ["auth", "login"], ["setup-token"]] {
            let r = try h.run(["shim"] + args, extraEnv: shared)
            XCTAssertNotEqual(r.code, 0, args.joined(separator: " "))
            XCTAssertTrue(r.stderr.contains("blocked"), r.stderr)
        }
        XCTAssertNil(h.read("auths"), "the real claude never ran")
        try h.run(["shim", "auth", "status"], extraEnv: shared)
        XCTAssertNotNil(h.read("auths"), "status still passes through")
    }

    func testMissingClaudeBinOverrideFallsBackToClaudeOnPath() throws {
        let stale = ["SESSIONHOPPER_CLAUDE_BIN": "/nonexistent/claude", "PATH": "\(h.t.path):/usr/bin:/bin"]
        let r = try h.run(["shim", "--version"], extraEnv: stale)
        XCTAssertEqual(r.code, 0, r.stderr)
        XCTAssertEqual(r.stdout, "9.9.9 (stub)\n")
        XCTAssertEqual(r.stderr.components(separatedBy: "SESSIONHOPPER_CLAUDE_BIN=/nonexistent/claude is missing").count, 2, "one warning: \(r.stderr)")
        try h.scenario("exit 0")
        let launched = try h.run(["shim", "hello"], extraEnv: stale)
        XCTAssertEqual(launched.code, 0, launched.stderr)
        XCTAssertTrue(h.launches.last?.contains("--settings") == true, "supervised launch still starts")
        XCTAssertEqual(launched.stderr.components(separatedBy: "is missing").count, 2, "shim + launch warn once: \(launched.stderr)")
        let doctor = try h.run(["doctor"], extraEnv: stale)
        XCTAssertTrue(doctor.stdout.contains("SESSIONHOPPER_CLAUDE_BIN=/nonexistent/claude is missing"), doctor.stdout)
        XCTAssertFalse(doctor.stderr.contains("is missing"), "doctor reports it in its list only")
    }

    func testNoClaudeAnywhereStillFails() throws {
        let r = try h.run(["shim", "--version"], extraEnv: ["SESSIONHOPPER_CLAUDE_BIN": "/nonexistent/claude", "SESSIONHOPPER_HOME": "/nonexistent-home"])
        XCTAssertNotEqual(r.code, 0)
        XCTAssertTrue(r.stderr.contains("claude not found"), r.stderr)
    }

    func testLinkNamedShimActsAsShim() throws {
        let link = h.t.appendingPathComponent("sessionhopper-shim")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: Harness.binary)
        let r = try h.run(["--version"], exe: link)
        XCTAssertEqual(r.stdout, "9.9.9 (stub)\n")
    }
}
