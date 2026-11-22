import XCTest
@testable import SessionHopperCore

final class McpShareTests: XCTestCase {
    let mcp: [String: Any] = ["mcpOAuth": ["context7|abc": ["accessToken": "a"], "atlassian|def": ["accessToken": "b"]]]

    func keys(_ o: [String: Any]?) -> [String] { (o ?? [:]).keys.sorted() }

    // MARK: plan

    func testAccountLoginIsStrippedAndMcpBackedUp() {
        let out = McpShare.plan(.object(mcp.merging(["claudeAiOauth": ["accessToken": "x"]]) { a, _ in a }), backup: nil)
        XCTAssertEqual(keys(out.store), ["mcpOAuth"])
        XCTAssertEqual(McpShare.servers(out.backup ?? [:]), ["atlassian", "context7"])
        XCTAssertEqual(keys(out.backup), ["mcpOAuth"], "the backup holds the MCP part only")
    }

    func testUnchangedStoreWritesNothing() {
        let out = McpShare.plan(.object(mcp), backup: mcp)
        XCTAssertNil(out.store)
        XCTAssertNil(out.backup, "an identical backup is not rewritten")
    }

    func testRestoresAfterLogoutDeletedTheStore() {
        let out = McpShare.plan(.missing, backup: mcp)
        XCTAssertEqual(McpShare.servers(out.store ?? [:]), ["atlassian", "context7"])
        XCTAssertNil(out.backup)
    }

    func testRestoresAfterLoginWipedTheMcpLogins() {
        let out = McpShare.plan(.object(["claudeAiOauth": ["accessToken": "x"], "mcpOAuth": [String: Any]()]), backup: mcp)
        XCTAssertEqual(keys(out.store), ["mcpOAuth"])
        XCTAssertEqual(McpShare.servers(out.store ?? [:]), ["atlassian", "context7"])
    }

    func testLoggingOutOfTheLastMcpServerIsNotUndone() {
        let out = McpShare.plan(.object(["mcpOAuth": [String: Any]()]), backup: mcp)
        XCTAssertNil(out.store, "not restored")
        XCTAssertEqual(McpShare.servers(out.backup ?? ["x": 1]), [], "the backup is emptied")
    }

    func testAnotherProfilesTokenIsNotInherited() throws {
        let box = Sandbox()
        var c = HopperConfig()
        c.profiles = [Profile(name: "first", dir: "/p/first", exportConfigDir: false), Profile(name: "second", dir: "/p/second", exportConfigDir: true)]
        let env = fileEnv(box, ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-second", Gateway.tokenOwner: "second"])
        try c.save(env.paths)
        var e = env.vars
        Gateway.applyClaudeToken(&e, c.profiles[0], env: env)
        XCTAssertNil(e["CLAUDE_CODE_OAUTH_TOKEN"], "started from inside second's session: first must not run on second's account")
        var plain = env.vars
        plain[Gateway.tokenOwner] = nil
        Gateway.applyClaudeToken(&plain, c.profiles[0], env: env)
        XCTAssertEqual(plain["CLAUDE_CODE_OAUTH_TOKEN"], "sk-ant-oat01-second", "a caller's own token still goes to the first profile")
    }

    func testInvalidJsonAndEmptyStoreAreLeftAlone() {
        XCTAssertNil(McpShare.plan(.invalid, backup: mcp).store)
        let empty = McpShare.plan(.missing, backup: nil)
        XCTAssertNil(empty.store)
        XCTAssertNil(empty.backup)
    }

    // MARK: guard on a real folder (file backend)

    func fileEnv(_ box: Sandbox, _ vars: [String: String] = [:]) -> HopperEnvironment {
        box.env(vars.merging(["SESSIONHOPPER_MCP_BACKEND": "file"]) { a, _ in a })
    }

    func testGuardStripsBacksUpAndRestoresOnDisk() throws {
        let box = Sandbox()
        let env = fileEnv(box)
        let dir = box.root.appendingPathComponent("store").path
        let creds = URL(fileURLWithPath: dir + "/.credentials.json")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: mcp.merging(["claudeAiOauth": ["accessToken": "x"]]) { a, _ in a }).write(to: creds)

        XCTAssertEqual(try McpShare.guardStore(dir, env: env), ["removed an account login from the shared MCP store"])
        XCTAssertEqual(keys(FileIO.jsonObject(FileIO.read(creds))), ["mcpOAuth"])
        let backup = URL(fileURLWithPath: dir + "/mcp-backup.json")
        XCTAssertEqual(McpShare.servers(FileIO.jsonObject(FileIO.read(backup)) ?? [:]), ["atlassian", "context7"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? Int, 0o700)

        try FileManager.default.removeItem(at: creds) // `/logout`
        XCTAssertEqual(try McpShare.guardStore(dir, env: env), ["restored MCP logins from the backup"])
        XCTAssertEqual(McpShare.servers(FileIO.jsonObject(FileIO.read(creds)) ?? [:]), ["atlassian", "context7"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: creds.path)[.posixPermissions] as? Int, 0o600)

        try Data("{not json".utf8).write(to: creds)
        XCTAssertEqual(try McpShare.guardStore(dir, env: env), ["the shared MCP store is not valid JSON; left alone"])
        XCTAssertEqual(String(decoding: FileIO.read(creds)!, as: UTF8.self), "{not json")
    }

    func testGuardRefusesASymlinkedStore() throws {
        let box = Sandbox()
        let dir = box.root.appendingPathComponent("store").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        box.write("{}", "elsewhere.json")
        try FileManager.default.createSymbolicLink(atPath: dir + "/.credentials.json", withDestinationPath: box.root.appendingPathComponent("elsewhere.json").path)
        XCTAssertThrowsError(try McpShare.guardStore(dir, env: fileEnv(box)))
    }

    func testHookGuardIsANoOpOutsideTheStore() {
        let box = Sandbox()
        let store = box.root.appendingPathComponent("store").path
        try? HopperConfig().with { $0.mcpStore = store }.save(box.env().paths)
        McpShare.guardIfShared(fileEnv(box))
        McpShare.guardIfShared(fileEnv(box, [McpShare.envVar: box.root.appendingPathComponent("other").path]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store))
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.root.appendingPathComponent("other").path))
        McpShare.guardIfShared(fileEnv(box, [McpShare.envVar: store]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store + "/.guard.lock"))
    }

    // MARK: launch environment

    func testOnlyOptedInTokenProfilesGetTheStore() throws {
        let box = Sandbox()
        let store = box.root.appendingPathComponent("store").path
        let tokenFile = box.root.appendingPathComponent("keys/t").path
        try Gateway.writePrivate(Data("sk-ant-oat01-test".utf8), to: URL(fileURLWithPath: tokenFile))
        var c = HopperConfig()
        c.mcpStore = store
        c.profiles = [
            Profile(name: "first", dir: "/p/first", exportConfigDir: false),
            Profile(name: "shared", dir: "/p/shared", exportConfigDir: true, keyFile: tokenFile, mcpShare: true),
            Profile(name: "notoken", dir: "/p/notoken", exportConfigDir: true, mcpShare: true),
            Profile(name: "own", dir: "/p/own", exportConfigDir: true, keyFile: tokenFile)
        ]
        // Started from inside a shared session: the inherited store must not leak into other profiles.
        let env = fileEnv(box, [McpShare.envVar: store, "DISABLE_LOGIN_COMMAND": "1", "DISABLE_LOGOUT_COMMAND": "1"])
        try c.save(env.paths)
        func child(_ i: Int) -> [String: String] {
            LaunchPlan.childEnvironment(base: env.vars, profile: c.profiles[i], sessionID: "s", env: env, userStatusCommand: nil)
        }
        let shared = child(1)
        XCTAssertEqual(shared[McpShare.envVar], store)
        XCTAssertEqual(shared["DISABLE_LOGIN_COMMAND"], "1")
        XCTAssertEqual(shared["DISABLE_LOGOUT_COMMAND"], "1")
        XCTAssertEqual(shared["CLAUDE_CODE_OAUTH_TOKEN"], "sk-ant-oat01-test")
        for i in [0, 2, 3] {
            let e = child(i)
            XCTAssertNil(e[McpShare.envVar], c.profiles[i].name)
            XCTAssertNil(e["DISABLE_LOGOUT_COMMAND"], c.profiles[i].name)
        }
        XCTAssertTrue(McpShare.hasToken(c.profiles[1], env: env))
        XCTAssertFalse(McpShare.hasToken(c.profiles[2], env: env))
        XCTAssertTrue(McpShare.inSharedSession(env))
    }

    func testConfigWithoutTheNewKeysStillLoads() throws {
        let old = #"{"profiles":[{"name":"a","dir":"/p/a","exportConfigDir":true}]}"#
        let c = try JSONDecoder().decode(HopperConfig.self, from: Data(old.utf8))
        XCTAssertNil(c.mcpStore)
        XCTAssertNil(c.profiles[0].mcpShare)
        let box = Sandbox()
        XCTAssertEqual(McpShare.store(c, env: box.env()), box.home.path + "/.claude-mcp-store")
    }

    // MARK: tokens

    func testWrappedSetupTokenIsJoined() throws {
        let full = SetupToken.prefix + String(repeating: "Ab3_-", count: 19)
        let wrapped = String(full.prefix(78)) + "\n  " + String(full.dropFirst(78)) + "\n"
        XCTAssertEqual(try SetupToken.parse(wrapped), full)
        XCTAssertThrowsError(try SetupToken.parse(String(full.prefix(78))), "a cut-off paste")
        XCTAssertThrowsError(try SetupToken.parse("sk-ant-api03-" + String(repeating: "a", count: 100)), "an API key")
        XCTAssertThrowsError(try SetupToken.parse(full + "é"))
    }

    func testSameAccountNeedsMatchingResetsAndUsage() {
        func l(_ p5: Double, _ r5: Double, _ p7: Double, _ r7: Double) -> ProfileLimits {
            ProfileLimits(fiveHour: LimitWindow(usedPercentage: p5, resetsAt: r5), sevenDay: LimitWindow(usedPercentage: p7, resetsAt: r7), sampledAt: 0)
        }
        XCTAssertTrue(SetupToken.sameAccount(l(12, 1000, 40, 9000), l(12, 1000, 40, 9000)))
        XCTAssertFalse(SetupToken.sameAccount(l(12, 1000, 40, 9000), l(12, 1000, 40, 9600)))
        XCTAssertFalse(SetupToken.sameAccount(l(12, 1000, 40, 9000), l(13, 1000, 40, 9000)))
        XCTAssertFalse(SetupToken.sameAccount(l(12, 1000, 40, 9000), limits(12)))
    }

    // MARK: resume by id prefix

    func testUniqueIdPrefixResolves() {
        let box = Sandbox()
        let projects = box.root.appendingPathComponent("projects")
        box.write("", "projects/-a/3f2a9c10-0000-4000-8000-000000000001.jsonl")
        box.write("", "projects/-b/3f2b0000-0000-4000-8000-000000000002.jsonl")
        XCTAssertEqual(Transcripts.idPrefix("3f2a", projects: projects), "3f2a9c10-0000-4000-8000-000000000001")
        XCTAssertNil(Transcripts.idPrefix("3f2", projects: projects), "too short")
        XCTAssertNil(Transcripts.idPrefix("3f2a9", projects: projects.appendingPathComponent("none")))
        box.write("", "projects/-b/3f2a0000-0000-4000-8000-000000000003.jsonl")
        XCTAssertNil(Transcripts.idPrefix("3f2a", projects: projects), "ambiguous")
    }
}

extension HopperConfig {
    func with(_ f: (inout HopperConfig) -> Void) -> HopperConfig { var c = self; f(&c); return c }
}
