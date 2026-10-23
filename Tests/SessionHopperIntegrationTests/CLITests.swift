import XCTest
@testable import SessionHopperCore

final class CLITests: XCTestCase {
    var h: Harness!

    override func setUpWithError() throws { h = try Harness() }
    override func tearDown() { h.cleanup() }

    func transcript(_ id: String, cwd: String, prompt: String) throws {
        try h.write(#"{"type":"user","cwd":"\#(cwd)","message":{"content":"\#(prompt)"}}"# + "\n",
                    "home/.claude/projects/\(Transcripts.dirName(for: cwd))/\(id).jsonl")
    }

    func testImportFoundBothProfiles() {
        let c = HopperConfig.load(h.env.paths)
        XCTAssertEqual(c.profiles.map(\.name), ["default", "work"])
        XCTAssertEqual(c.profiles.map(\.exportConfigDir), [false, true])
    }

    func testResumeAdoptsAndFollowsTheSessionsDirectory() throws {
        let id = "aaaaaaaa-0000-0000-0000-000000000001"
        let elsewhere = h.t.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try transcript(id, cwd: elsewhere.path, prompt: "old work")
        try h.scenario("exit 0")
        let r = try h.run(["--resume", id])
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(h.launches[0].contains("--resume \(id) --settings"))
        XCTAssertFalse(h.launches[0].contains("--session-id"))
        XCTAssertEqual(h.read("cwds")?.trimmingCharacters(in: .newlines), elsewhere.path)
        XCTAssertTrue(r.stderr.contains("continuing there"))
    }

    func testContinueAndBareResume() throws {
        try transcript("aaaaaaaa-0000-0000-0000-000000000001", cwd: h.work.path, prompt: "older")
        Thread.sleep(forTimeInterval: 1.1)
        try transcript("aaaaaaaa-0000-0000-0000-000000000002", cwd: h.work.path, prompt: "newer")
        let list = try h.run(["--resume"])
        XCTAssertEqual(list.code, 0)
        XCTAssertTrue(list.stdout.contains("newer") && list.stdout.contains("older"))
        XCTAssertTrue(h.launches.isEmpty, "a bare --resume lists, it does not launch")
        try h.scenario("exit 0")
        try h.run(["-c"])
        XCTAssertTrue(h.launches.first?.contains("--resume aaaaaaaa-0000-0000-0000-000000000002") ?? false)
    }

    func testRefusesNonIdResume() throws {
        let r = try h.run(["--resume", "my-session-name"])
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(h.launches.isEmpty)
    }

    func testUsersStatusLineStillShows() throws {
        try #"{"statusLine":{"type":"command","command":"cat > /dev/null; echo user-line","padding":2}}"#
            .write(to: h.defaultDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        try h.scenario("usage 33; exit 0")
        try h.run([])
        XCTAssertEqual(h.read("statusline-out"), "user-line\n")
        XCTAssertTrue(h.launches[0].contains(#""padding":2"#))
        XCTAssertEqual(LimitStore.read("default", h.env.paths)?.fiveHour?.usedPercentage, 33)
    }

    func testDoctorStatusLogAndConfig() throws {
        let d = try h.run(["doctor"])
        XCTAssertEqual(d.code, 0, d.stdout)
        XCTAssertTrue(d.stdout.contains("9.9.9 (stub)"))
        XCTAssertTrue(d.stdout.contains("default (~/.claude): logged in"))
        XCTAssertTrue(d.stdout.contains("share one projects/"))

        XCTAssertEqual(try h.run(["config", "auto-move", "on"]).code, 0)
        XCTAssertTrue(HopperConfig.load(h.env.paths).autoMove)
        XCTAssertEqual(try h.run(["config", "suggest", "99"]).code, 1, "suggest must stay below park")

        let s = try h.run(["status", "--json"])
        XCTAssertNotNil(try JSONDecoder().decode(HopperSnapshot.self, from: Data(s.stdout.utf8)))
        XCTAssertTrue(try h.run(["status"]).stdout.contains("1. default"))
        XCTAssertTrue(try h.run(["log"]).stdout.contains("No hand-offs yet"))
    }

    func testDoctorWarnsWhenHistoryIsNotShared() throws {
        try FileManager.default.removeItem(at: h.workDir.appendingPathComponent("projects"))
        try FileManager.default.createDirectory(at: h.workDir.appendingPathComponent("projects"), withIntermediateDirectories: true)
        XCTAssertTrue(try h.run(["doctor"]).stdout.contains("projects/ not shared by: work"))
    }

    func testProfilesAddOrderAndRemove() throws {
        let r = try h.run(["profiles", "add", "spare", "--no-login"])
        XCTAssertEqual(r.code, 0, r.stderr)
        let dir = h.home.appendingPathComponent(".claude-spare")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("projects").path))
        XCTAssertTrue(h.launches.isEmpty, "--no-login never starts claude")
        try h.run(["profiles", "order", "spare,work"])
        XCTAssertEqual(HopperConfig.load(h.env.paths).profiles.map(\.name), ["spare", "work", "default"])
        try h.run(["profiles", "remove", "spare"])
        XCTAssertEqual(HopperConfig.load(h.env.paths).profiles.map(\.name), ["work", "default"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "remove never deletes the folder")
    }

    func testInstallHooksNeedsAnExplicitProfile() throws {
        XCTAssertEqual(try h.run(["install-hooks"]).code, 1)
        XCTAssertEqual(try h.run(["install-hooks", "--profile", "work"]).code, 0)
        XCTAssertTrue(HookInstaller.isInstalled(HopperConfig.load(h.env.paths).profile(named: "work")!))
        XCTAssertEqual(try h.run(["uninstall-hooks", "--profile", "work"]).code, 0)
        XCTAssertFalse(HookInstaller.isInstalled(HopperConfig.load(h.env.paths).profile(named: "work")!))
    }

    func testSwitchOutsideASessionNeedsAnId() throws {
        XCTAssertEqual(try h.run(["switch"]).code, 1)
        XCTAssertEqual(try h.run(["switch", "--session", "nope"]).code, 1)
    }
}
