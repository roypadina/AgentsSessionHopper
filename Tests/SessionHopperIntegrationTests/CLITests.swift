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

    func titled(_ id: String, cwd: String, prompt: String, title: String) throws {
        try h.write(#"{"type":"user","cwd":"\#(cwd)","message":{"content":"\#(prompt)"}}"# + "\n"
                    + #"{"type":"ai-title","aiTitle":"auto name"}"# + "\n" + #"{"type":"custom-title","customTitle":"\#(title)"}"# + "\n",
                    "home/.claude/projects/\(Transcripts.dirName(for: cwd))/\(id).jsonl")
    }

    func testSessionsShowTitlesAllAndAllDirs() throws {
        let other = h.t.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try titled("aaaaaaaa-0000-0000-0000-000000000001", cwd: h.work.path, prompt: "here work", title: "Here Name")
        try titled("aaaaaaaa-0000-0000-0000-000000000002", cwd: other.path, prompt: "there work", title: "There Name")
        let here = try h.run(["--sessions", "all"])
        XCTAssertEqual(here.code, 0)
        XCTAssertTrue(here.stdout.contains("Here Name - here work"), here.stdout)
        XCTAssertFalse(here.stdout.contains("There Name"))
        let all = try h.run(["sessions", "--all-dirs"])
        XCTAssertTrue(all.stdout.contains("There Name") && all.stdout.contains("Here Name"), all.stdout)
        XCTAssertTrue(all.stdout.contains("other"), "rows from other folders name the folder")
        XCTAssertTrue(h.launches.isEmpty)
    }

    func testResumeByName() throws {
        let id = "aaaaaaaa-0000-0000-0000-000000000003"
        try titled(id, cwd: h.work.path, prompt: "x", title: "Avendra Integration")
        try h.scenario("exit 0")
        XCTAssertEqual(try h.run(["--resume", "Avendra Integration"]).code, 0)
        XCTAssertTrue(h.launches.first?.contains("--resume \(id) --settings") ?? false)
    }

    func testAccountIsAnAliasForProfile() throws {
        try h.scenario("exit 0")
        try h.run(["--account", "work"])
        XCTAssertTrue(h.launches[0].hasPrefix(h.workDir.path), h.launches[0])
        XCTAssertFalse(h.launches[0].contains("--account"))
    }

    func testCallersSettingsAreMergedIntoOneFlag() throws {
        // cmux (and others) pass their own --settings; Claude Code keeps only one of several.
        try h.scenario("exit 0")
        try h.run(["--settings", #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"cmux-stop-hook"}]}]},"model":"x"}"#, "hi"])
        let l = h.launches[0]
        XCTAssertEqual(l.components(separatedBy: "--settings ").count, 2, "exactly one --settings: \(l)")
        XCTAssertTrue(l.contains("cmux-stop-hook"), l)
        XCTAssertTrue(l.contains(#"sessionhopper' hook"#), l)
        XCTAssertTrue(l.contains(#""model":"x""#), l)
        XCTAssertTrue(l.contains(#""statusLine":{"command":"#), l)
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
        XCTAssertEqual(try h.run(["config", "move-now", "on"]).code, 0)
        XCTAssertTrue(HopperConfig.load(h.env.paths).moveNowAtHard)
        XCTAssertEqual(try h.run(["config", "suggest", "99"]).code, 1, "suggest must stay below park")

        let s = try h.run(["status", "--json"])
        XCTAssertNotNil(try JSONDecoder().decode(HopperSnapshot.self, from: Data(s.stdout.utf8)))
        XCTAssertTrue(try h.run(["status"]).stdout.contains("1. default"))
        XCTAssertTrue(try h.run(["log"]).stdout.contains("No hand-offs yet"))
    }

    func testDoctorWarnsAboutAnExportedKeyAndMissingSamples() throws {
        let d = try h.run(["doctor"], extraEnv: ["ANTHROPIC_API_KEY": "sk-test"])
        XCTAssertTrue(d.stdout.contains("warn  ANTHROPIC_API_KEY set in this environment"), d.stdout)
        XCTAssertTrue(d.stdout.contains("warn  default: no usage sample yet"), d.stdout)
        XCTAssertFalse(try h.run(["doctor"]).stdout.contains("ANTHROPIC_API_KEY"))
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
