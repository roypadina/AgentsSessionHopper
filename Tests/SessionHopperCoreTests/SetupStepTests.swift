import XCTest
@testable import SessionHopperCore

/// Setup steps: sharing existing profiles, the shell alias line, the shim link, the SessionStart note.
final class SetupStepTests: XCTestCase {
    let sb = Sandbox()
    let fm = FileManager.default

    func text(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
    func put(_ s: String, _ u: URL, age: TimeInterval = 0) {
        try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! s.write(to: u, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: u.path)
    }

    func testShareLinksMergesAndNeverDeletes() throws {
        let base = sb.profileDir(".claude"), work = sb.profileDir(".claude-work")
        let b = Profile(name: "default", dir: base.path, exportConfigDir: false), w = Profile(name: "work", dir: work.path, exportConfigDir: true)
        put("base only", base.appendingPathComponent("projects/-a/1.jsonl"))
        put("old base copy", base.appendingPathComponent("projects/-a/2.jsonl"), age: 500)
        put("newer in work", work.appendingPathComponent("projects/-a/2.jsonl"), age: 10)
        put("older in work", work.appendingPathComponent("projects/-a/1.jsonl"), age: 900)
        put("work only", work.appendingPathComponent("projects/-b/3.jsonl"))
        put("# mine", work.appendingPathComponent("CLAUDE.md"))
        put("# base", base.appendingPathComponent("CLAUDE.md"))
        try fm.createDirectory(at: work.appendingPathComponent("todos"), withIntermediateDirectories: true)  // empty

        let plan = try Setup.share(w, base: b, dryRun: true, now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(plan.contains { $0.hasPrefix("projects: moved to projects.ash-backup-") }, "\(plan)")
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: work.appendingPathComponent("projects").path), "dry run changes nothing")

        let did = try Setup.share(w, base: b, dryRun: false, now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(did.contains("todos: empty folder replaced by a link"), "\(did)")
        for item in ["projects", "CLAUDE.md", "todos", "file-history"] {
            XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: work.appendingPathComponent(item).path), item)
        }
        let projects = base.appendingPathComponent("projects")
        XCTAssertEqual(text(projects.appendingPathComponent("-a/1.jsonl")), "base only", "the newer copy stays")
        XCTAssertEqual(text(projects.appendingPathComponent("-a/2.jsonl")), "newer in work", "the newer copy wins")
        XCTAssertEqual(text(projects.appendingPathComponent("-b/3.jsonl")), "work only")
        let backups = try fm.contentsOfDirectory(atPath: work.path).filter { $0.contains(".ash-backup-") }
        XCTAssertEqual(Set(backups.map { $0.components(separatedBy: ".ash-backup-")[0] }), ["projects", "CLAUDE.md"])
        let pb = work.appendingPathComponent(backups.first { $0.hasPrefix("projects") }!)
        XCTAssertEqual(text(pb.appendingPathComponent("-a/1.jsonl")), "older in work", "the profile's own copy is kept")
        XCTAssertEqual(text(pb.appendingPathComponent(".replaced-in-default/-a/2.jsonl")), "old base copy", "the replaced base copy is kept")
        XCTAssertEqual(text(work.appendingPathComponent("CLAUDE.md")), "# base")
        XCTAssertTrue(try Setup.share(w, base: b, dryRun: false).allSatisfy { $0.hasSuffix("already shared") })
    }

    func testShareRefusesWhileClaudeRunsThere() throws {
        let base = sb.profileDir(".claude"), work = sb.profileDir(".claude-work")
        put(#"{"pid":\#(getpid()),"sessionId":"x"}"#, work.appendingPathComponent("sessions/\(getpid()).json"))
        XCTAssertThrowsError(try Setup.share(Profile(name: "work", dir: work.path, exportConfigDir: true),
                                             base: Profile(name: "default", dir: base.path, exportConfigDir: false), dryRun: false))
    }

    func testShellLineInstallRemoveAndClashes() throws {
        let vars = ["SHELL": "/bin/zsh"]
        let real = sb.root.appendingPathComponent("dotfiles/zshrc")
        put("export A=1", real)
        try fm.createSymbolicLink(at: sb.home.appendingPathComponent(".zshrc"), withDestinationURL: real)
        XCTAssertTrue(try Setup.installShell(.zsh, cli: "/A p/sessionhopper", home: sb.home, vars: vars).hasPrefix("added"))
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: sb.home.appendingPathComponent(".zshrc").path), "a dotfiles link stays a link")
        XCTAssertEqual(text(real), "export A=1\nalias claude=\"'/A p/sessionhopper' shim\"  # AgentsSessionHopper\n")
        XCTAssertNotNil(text(real.appendingPathExtension("ash-backup")))
        XCTAssertTrue(Setup.shellInstalled(.zsh, home: sb.home, vars: vars))
        XCTAssertTrue(try Setup.installShell(.zsh, cli: "/x", home: sb.home, vars: vars).hasPrefix("already"))
        _ = try Setup.removeShell(.zsh, home: sb.home, vars: vars)
        XCTAssertEqual(text(real), "export A=1\n")

        put("claude() { command claude --model opus \"$@\"; }\n", sb.home.appendingPathComponent(".bash_profile"))
        XCTAssertThrowsError(try Setup.installShell(.bash, cli: "/x", home: sb.home, vars: [:]), "the user's own claude function is not shadowed")

        _ = try Setup.installShell(.fish, cli: "/x/sessionhopper", home: sb.home, vars: [:])
        let fish = sb.home.appendingPathComponent(".config/fish/conf.d/sessionhopper.fish")
        XCTAssertEqual(text(fish), "alias claude \"'/x/sessionhopper' shim\"  # AgentsSessionHopper\n")
        _ = try Setup.removeShell(.fish, home: sb.home, vars: [:])
        XCTAssertFalse(fm.fileExists(atPath: fish.path), "fish gets its own file, removed whole")

        XCTAssertEqual(Setup.rcFile(.tcsh, home: sb.home, vars: [:]).lastPathComponent, ".cshrc")
        XCTAssertEqual(Setup.aliasLine(.tcsh, cli: "/x"), "alias claude \"'/x' shim\"  # AgentsSessionHopper")
        XCTAssertEqual(Setup.rcFile(.zsh, home: sb.home, vars: ["ZDOTDIR": "/z"]).path, "/z/.zshrc")
        XCTAssertEqual(Setup.shellKind(["SHELL": "/bin/tcsh"]), .tcsh)
        XCTAssertEqual(Setup.shellKind([:]), .zsh)
    }

    func testShimLink() throws {
        XCTAssertTrue(try Setup.linkShim(cli: "/x/sessionhopper", home: sb.home).hasPrefix("linked"))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: Setup.shimLink(home: sb.home).path), "/x/sessionhopper")
        XCTAssertTrue(try Setup.linkShim(cli: "/x/sessionhopper", home: sb.home).hasPrefix("already"))
    }

    func testSupervisedSessionIsToldAtStart() throws {
        let env = sb.env(["SESSIONHOPPER_SESSION_ID": "s1", "SESSIONHOPPER_PROFILE": "work"])
        var c = HopperConfig()
        c.profiles = [profile("default"), profile("work")]
        try c.save(env.paths)
        let out = HookHandler.handle(input: Data(#"{"hook_event_name":"SessionStart","source":"resume","session_id":"s1"}"#.utf8), env: env, installedProfile: nil)
        XCTAssertTrue(out?.contains("on profile work (profiles in order: default, work)") ?? false, out ?? "nil")
        XCTAssertTrue(out?.contains(#""hookEventName":"SessionStart""#) ?? false)
        XCTAssertNil(HookHandler.handle(input: Data(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#.utf8), env: sb.env(), installedProfile: nil), "not supervised: nothing")
    }
}
