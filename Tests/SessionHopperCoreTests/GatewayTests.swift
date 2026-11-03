import XCTest
@testable import SessionHopperCore

final class GatewayTests: XCTestCase {
    func gateway(_ name: String = "or", keyFile: String? = nil, models: [String: String]? = nil, resets: String? = nil) -> Profile {
        Profile(name: name, dir: "/p/base", exportConfigDir: false, kind: Gateway.openRouter, keyFile: keyFile, models: models, resets: resets)
    }

    func testOldConfigLoadsAndGatewayFieldsRoundTrip() throws {
        let old = #"{"profiles":[{"name":"a","dir":"/p/a","exportConfigDir":true}]}"#
        let c = try JSONDecoder().decode(HopperConfig.self, from: Data(old.utf8))
        XCTAssertFalse(c.profiles[0].isGateway)
        XCTAssertNil(c.profiles[0].kind)
        var n = c
        n.profiles.append(gateway(models: ["opus": "anthropic/claude-opus-5"], resets: "weekly"))
        let back = try JSONDecoder().decode(HopperConfig.self, from: JSONEncoder().encode(n))
        XCTAssertEqual(back, n)
        XCTAssertTrue(back.profiles[1].isGateway)
    }

    func testEnvironmentPointsClaudeAtTheGateway() {
        let e = Gateway.environment(gateway(models: ["opus": "anthropic/claude-opus-5", "haiku": "anthropic/claude-haiku-5"]), key: "sk-or-x")
        XCTAssertEqual(e["ANTHROPIC_BASE_URL"], "https://openrouter.ai/api")
        XCTAssertEqual(e["ANTHROPIC_AUTH_TOKEN"], "sk-or-x")
        XCTAssertEqual(e["ANTHROPIC_API_KEY"], "")
        XCTAssertEqual(e["ENABLE_TOOL_SEARCH"], "true")
        XCTAssertEqual(e["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"], "1")
        XCTAssertEqual(e["ANTHROPIC_DEFAULT_OPUS_MODEL"], "anthropic/claude-opus-5")
        XCTAssertEqual(e["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "anthropic/claude-haiku-5")
        XCTAssertNil(e["ANTHROPIC_DEFAULT_SONNET_MODEL"])
    }

    func testModelAliasIsRewritten() {
        let p = gateway(models: ["opus": "anthropic/claude-opus-5"])
        XCTAssertEqual(Gateway.modelArgs(["-p", "--model", "opus"], p), ["-p", "--model", "anthropic/claude-opus-5"])
        XCTAssertEqual(Gateway.modelArgs(["--model=opus"], p), ["--model=anthropic/claude-opus-5"])
        XCTAssertEqual(Gateway.modelArgs(["--model", "sonnet"], p), ["--model", "sonnet"])
    }

    func testKeyFileMustBePrivate() throws {
        let box = Sandbox()
        let env = box.env()
        let p = gateway(keyFile: box.root.appendingPathComponent("k/or.key").path)
        XCTAssertThrowsError(try Gateway.key(p, env: env))
        XCTAssertEqual(try Gateway.storeKey("sk-or-v1-abc\n", for: p, env: env), env.tilde(p.keyFile!))
        XCTAssertEqual(try Gateway.key(p, env: env), "sk-or-v1-abc")
        let mode = try FileManager.default.attributesOfItem(atPath: p.keyFile!)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        chmod(p.keyFile!, 0o644)
        XCTAssertThrowsError(try Gateway.key(p, env: env))
        XCTAssertThrowsError(try Gateway.storeKey("not a key; rm -rf", for: p, env: env))
    }

    #if !os(macOS)
    func testLinuxReadsSystemdCredentialThenDefaultFile() throws {
        let box = Sandbox()
        let p = gateway()
        let env = box.env(["XDG_CONFIG_HOME": box.root.appendingPathComponent("cfg").path])
        try Gateway.storeKey("from-file", for: p, env: env)
        XCTAssertEqual(try Gateway.key(p, env: env), "from-file")
        let creds = box.root.appendingPathComponent("creds")
        try Gateway.writePrivate(Data("from-systemd\n".utf8), to: creds.appendingPathComponent("or"))
        let env2 = box.env(["XDG_CONFIG_HOME": box.root.appendingPathComponent("cfg").path, "CREDENTIALS_DIRECTORY": creds.path])
        XCTAssertEqual(try Gateway.key(p, env: env2), "from-systemd")
    }
    #endif

    func testNextResetIsTheNextUTCBoundary() {
        let now = 1_793_700_000.0 // Tue 2026-11-03 10:00 UTC
        XCTAssertEqual(Gateway.nextReset(gateway(), now: now), 1_793_750_400) // Wed 00:00 UTC
        XCTAssertEqual(Gateway.nextReset(gateway(resets: "weekly"), now: now), 1_794_182_400) // Mon 11-09
        XCTAssertEqual(Gateway.nextReset(gateway(resets: "monthly"), now: now), 1_796_083_200) // 12-01
    }

    func testGatewayIsLastResortAndOffersTheWayBack() {
        let a = profile("a"), b = profile("b"), or = gateway()
        var c = HopperConfig()
        c.profiles = [or, a, b] // even when listed first
        let none = Policy(config: c, limits: [:], now: 0)
        XCTAssertEqual(none.pick(c.profiles)?.name, "a")
        let full = Policy(config: c, limits: ["a": limits(99), "b": limits(98)], now: 0)
        XCTAssertEqual(full.pick(c.profiles)?.name, "or")
        let nearly = Policy(config: c, limits: ["a": limits(99), "b": limits(90)], now: 0)
        XCTAssertEqual(nearly.pick(c.profiles)?.name, "b", "a subscription between the thresholds beats paying")
        let spent = Policy(config: c, limits: ["a": limits(99), "b": limits(98),
                                               "or": ProfileLimits(fiveHour: nil, sevenDay: nil, spendLimit: LimitWindow(usedPercentage: 100, resetsAt: nil), sampledAt: 0)], now: 0)
        XCTAssertNil(spent.pick(c.profiles))
        // On the gateway while a subscription has room again → suggest going back.
        XCTAssertEqual(none.evaluate(current: or, order: c.profiles, held: false), .suggest(to: "a", percent: 0))
        c.autoMove = true
        XCTAssertEqual(Policy(config: c, limits: [:], now: 0).evaluate(current: or, order: c.profiles, held: false), .autoMove(to: "a", percent: 0))
        // Past the hard threshold with auto-move on, the gateway is a move target once subscriptions are full.
        XCTAssertEqual(Policy(config: c, limits: ["a": limits(99), "b": limits(98)], now: 0).evaluate(current: a, order: c.profiles, held: false),
                       .autoMove(to: "or", percent: 99))
    }
}
