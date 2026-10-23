import XCTest
@testable import SessionHopperCore

final class InstallerTests: XCTestCase {
    let sb = Sandbox()
    let original = #"{"model":"opus","hooks":{"StopFailure":[{"hooks":[{"type":"command","command":"my-alert"}]}],"Stop":[{"hooks":[{"type":"command","command":"x"}]}]},"statusLine":{"type":"command","command":"~/.claude/sl.sh","padding":1}}"#

    func testInstallIsIdempotentAndUninstallRestores() throws {
        let dir = sb.profileDir(".claude-w", settings: original)
        let p = Profile(name: "w", dir: dir.path, exportConfigDir: true)
        let env = sb.env()
        let settings = dir.appendingPathComponent("settings.json")

        try HookInstaller.install(p, env: env)
        let once = try Data(contentsOf: settings)
        try HookInstaller.install(p, env: env)
        XCTAssertEqual(try Data(contentsOf: settings), once, "idempotent")
        XCTAssertTrue(HookInstaller.isInstalled(p))

        let obj = FileIO.jsonObject(once)!
        let sl = obj["statusLine"] as! [String: Any]
        XCTAssertEqual(sl["command"] as? String, "'/opt/x/sessionhopper' statusline --profile w")
        XCTAssertEqual(sl["padding"] as? Int, 1)
        let failures = (obj["hooks"] as! [String: Any])["StopFailure"] as! [[String: Any]]
        XCTAssertEqual(failures.count, 2, "the user's own StopFailure hook stays")
        XCTAssertEqual(json(FileIO.readString(env.paths.savedStatusLine("w")))?["command"] as? String, "~/.claude/sl.sh")

        try HookInstaller.uninstall(p, env: env)
        XCTAssertEqual(FileIO.jsonObject(try Data(contentsOf: settings)) as NSDictionary?, json(original) as NSDictionary?)
        XCTAssertFalse(HookInstaller.isInstalled(p))
        XCTAssertFalse((try FileManager.default.contentsOfDirectory(atPath: env.paths.backupsDir.path)).isEmpty, "a backup per write")
    }

    func testInstallWithoutSettingsAndUninstallLeavesEmptyObject() throws {
        let dir = sb.profileDir(".claude-n")
        let p = Profile(name: "n", dir: dir.path, exportConfigDir: true)
        try HookInstaller.install(p, env: sb.env())
        try HookInstaller.uninstall(p, env: sb.env())
        XCTAssertEqual(FileIO.jsonObject(FileIO.read(dir.appendingPathComponent("settings.json")))?.count, 0)
    }

    func testRefusesBrokenSettings() {
        let dir = sb.profileDir(".claude-b", settings: "{ not json")
        XCTAssertThrowsError(try HookInstaller.install(Profile(name: "b", dir: dir.path, exportConfigDir: true), env: sb.env()))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("settings.json"), encoding: .utf8), "{ not json")
    }
}

final class ProfileTests: XCTestCase {
    let sb = Sandbox()

    func testDiscovery() {
        sb.profileDir(".claude")
        sb.profileDir(".claude-work")
        sb.profileDir(".claude3")
        try! FileManager.default.createDirectory(at: sb.home.appendingPathComponent(".claude-unrelated-tool"), withIntermediateDirectories: true)
        sb.write("{}", "home/.claude.json")
        let found = Profiles.discover(home: sb.home)
        XCTAssertEqual(found.map(\.name), ["default", "work", "claude3"])
        XCTAssertEqual(found.map(\.exportConfigDir), [false, true, true], "CLAUDE_CONFIG_DIR stays unset for ~/.claude")
    }

    func testCreateLinksHistoryAndNeverOverwrites() throws {
        let base = sb.profileDir(".claude", settings: #"{"a":1}"#)
        sb.write("rules", "home/.claude/CLAUDE.md")
        let baseProfile = Profile(name: "default", dir: base.path, exportConfigDir: false)
        let dir = sb.home.appendingPathComponent(".claude-work")
        _ = try Profiles.create(name: "work", dir: dir, base: baseProfile, home: sb.home, shareSetup: true)
        let fm = FileManager.default
        XCTAssertEqual(URL(fileURLWithPath: try fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("projects").path)).resolvingSymlinksInPath(),
                       base.appendingPathComponent("projects").resolvingSymlinksInPath())
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("CLAUDE.md").path))
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("settings.json").path), "settings.json is copied")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("settings.json"), encoding: .utf8), #"{"a":1}"#)

        // A second profile with its own history: left alone.
        let own = sb.profileDir(".claude-own")
        let did = try Profiles.create(name: "own", dir: own, base: baseProfile, home: sb.home, shareSetup: false)
        XCTAssertTrue(did.contains("projects: exists, left alone"))
        XCTAssertThrowsError(try Profiles.create(name: "bad name", dir: own, base: nil, home: sb.home, shareSetup: false))
    }

    func testEnvironmentAndLogin() {
        let def = Profile(name: "default", dir: "/h/.claude", exportConfigDir: false)
        let work = Profile(name: "work", dir: "/h/.claude-work", exportConfigDir: true)
        XCTAssertNil(Profiles.environment(for: def, base: ["CLAUDE_CONFIG_DIR": "/elsewhere"])["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(Profiles.environment(for: work, base: [:])["CLAUDE_CONFIG_DIR"], "/h/.claude-work")
        XCTAssertEqual(Profiles.loginCommand(for: work) { $0.replacingOccurrences(of: "/h", with: "~") }, "CLAUDE_CONFIG_DIR=~/.claude-work claude auth login")
    }
}

final class LaunchPlanTests: XCTestCase {
    func testRelaunchDropsTrailingPrompt() {
        XCTAssertEqual(LaunchPlan.relaunchArgs(["fix the tests"]), [])
        XCTAssertEqual(LaunchPlan.relaunchArgs(["--model", "opus"]), ["--model", "opus"])
        XCTAssertEqual(LaunchPlan.relaunchArgs(["--model", "opus", "fix it"]), ["--model", "opus"])
        XCTAssertEqual(LaunchPlan.relaunchArgs(["--verbose"]), ["--verbose"])
        XCTAssertEqual(LaunchPlan.relaunchArgs([]), [])
    }

    func testSettingsJSON() {
        let s = json(LaunchPlan.settingsJSON(selfPath: "/a b/sessionhopper", userStatusLine: ["command": "x", "refreshInterval": 5]))!
        let hooks = s["hooks"] as! [String: Any]
        XCTAssertEqual(Set(hooks.keys), Set(LaunchPlan.hookEvents))
        let cmd = (((hooks["Stop"] as! [[String: Any]])[0]["hooks"]) as! [[String: Any]])[0]["command"] as? String
        XCTAssertEqual(cmd, "'/a b/sessionhopper' hook")
        let sl = s["statusLine"] as! [String: Any]
        XCTAssertEqual(sl["command"] as? String, "'/a b/sessionhopper' statusline")
        XCTAssertEqual(sl["refreshInterval"] as? Int, 5)
    }

    func testChildEnvironment() {
        let sb = Sandbox()
        let e = LaunchPlan.childEnvironment(base: ["CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "old", "PATH": "/bin"],
                                            profile: profile("w"), sessionID: "sid", env: sb.env(), userStatusCommand: nil)
        XCTAssertNil(e["CLAUDECODE"])
        XCTAssertNil(e["CLAUDE_CODE_SESSION_ID"])
        XCTAssertEqual(e["PATH"], "/bin")
        XCTAssertEqual(e["CLAUDE_CONFIG_DIR"], "/p/w")
        XCTAssertEqual(e["SESSIONHOPPER_SESSION_ID"], "sid")
        XCTAssertEqual(e["SESSIONHOPPER_PROFILE"], "w")
        XCTAssertNil(e["SESSIONHOPPER_USER_STATUSLINE"])
    }

    func testContinuePromptListsJobs() {
        let p = LaunchPlan.continuePrompt(jobs: ["shell b1 - tail -f build.log"], limitStop: false)
        XCTAssertTrue(p.contains("- shell b1 - tail -f build.log"))
        XCTAssertTrue(LaunchPlan.continuePrompt(jobs: [], limitStop: true).contains("usage limit"))
    }
}

final class TranscriptAndLogTests: XCTestCase {
    let sb = Sandbox()

    func testDirName() {
        XCTAssertEqual(Transcripts.dirName(for: "/Users/me/Code/my_app.v2"), "-Users-me-Code-my-app-v2")
    }

    func testListNewestFirstSkippingLiveAndSubagents() throws {
        let projects = sb.root.appendingPathComponent("projects")
        let cwd = "/work/app"
        let dir = "projects/\(Transcripts.dirName(for: cwd))"
        sb.write(#"{"type":"user","cwd":"/work/app","message":{"content":"old task"}}"#, "\(dir)/a.jsonl")
        sb.write(#"{"type":"user","cwd":"/work/app","message":{"content":[{"type":"text","text":"new   task"}]}}"#, "\(dir)/b.jsonl")
        sb.write(#"{"isSidechain":true,"type":"user","message":{"content":"sub"}}"#, "\(dir)/c.jsonl")
        sb.write(#"{"type":"user","message":{"content":"live one"}}"#, "\(dir)/d.jsonl")
        let fm = FileManager.default
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: projects.appendingPathComponent(Transcripts.dirName(for: cwd)).appendingPathComponent("a.jsonl").path)
        let list = Transcripts.list(cwd: cwd, projects: projects, live: ["d"], limit: 10)
        XCTAssertEqual(list.map(\.id), ["b", "a"])
        XCTAssertEqual(list.first?.firstPrompt, "new task")
        XCTAssertEqual(Transcripts.find("a", projects: projects).flatMap(Transcripts.cwd), "/work/app")
    }

    func testEventLogRoundTrip() {
        let paths = sb.env().paths
        EventLog.append(HopperEvent(type: "switch", session: "s", from: "a", to: "b", trigger: "confirm", source: "cli"), paths)
        EventLog.append(HopperEvent(type: "park", session: "s", from: "b"), paths)
        let read = EventLog.read(paths)
        XCTAssertEqual(read.map(\.type), ["switch", "park"])
        XCTAssertEqual(read.first?.v, 1)
        XCTAssertEqual(EventLog.read(paths, last: 1).map(\.type), ["park"])
    }
}

final class RetentionTests: XCTestCase {
    func testPruneDropsOldEntries() {
        let sb = Sandbox()
        let paths = sb.env().paths
        EventLog.append(HopperEvent(type: "switch", ts: "2020-01-01T10:00:00+00:00"), paths)
        EventLog.append(HopperEvent(type: "park"), paths)
        EventLog.prune(paths, days: 90)
        XCTAssertEqual(EventLog.read(paths).map(\.type), ["park"])
    }

    func testLoginScriptRunsClaudesOwnLogin() throws {
        let sb = Sandbox()
        let url = try Claude.loginScript(Profile(name: "w", dir: "/h/.claude-w", exportConfigDir: true), env: sb.env())
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("export CLAUDE_CONFIG_DIR='/h/.claude-w'"))
        XCTAssertTrue(text.hasSuffix("auth login\n"))
    }
}
