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
        XCTAssertEqual(h.launches.last, "<unset> auth status")
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

    func testLinkNamedShimActsAsShim() throws {
        let link = h.t.appendingPathComponent("sessionhopper-shim")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: Harness.binary)
        let r = try h.run(["--version"], exe: link)
        XCTAssertEqual(r.stdout, "9.9.9 (stub)\n")
    }
}
