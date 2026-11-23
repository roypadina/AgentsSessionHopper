import XCTest
@testable import SessionHopperCore

final class PluginShareTests: XCTestCase {
    var box: Sandbox!

    func setup() throws -> HopperConfig {
        box = Sandbox()
        var c = HopperConfig()
        c.profiles = ["base", "two", "three"].map { Profile(name: $0, dir: box.root.appendingPathComponent($0).path, exportConfigDir: true) }
        box.write(#"{"enabledPlugins":{"a@m":true,"b@m":false},"extraKnownMarketplaces":{"m":{"source":{"source":"github","repo":"x/y"}}},"model":"opus"}"#, "base/settings.json")
        box.write(#"{"enabledPlugins":{"c@m":true,"gone@m":true},"model":"sonnet","env":{"KEEP":"1"}}"#, "two/settings.json")
        box.write(#"{"plugins":{"a@m":[{"installPath":"\#(box.root.path)/base/plugins/cache/m/a/1"}],"c@m":[{"installPath":"\#(box.root.path)/base/plugins/cache/m/c/1"}]}}"#, "base/plugins/installed_plugins.json")
        return c
    }

    func json(_ path: String) -> [String: Any] { FileIO.jsonObject(FileIO.read(box.root.appendingPathComponent(path))) ?? [:] }

    func testShareWritesTheEnvKeyAndSyncsTheOnOffList() throws {
        var c = try setup()
        try PluginShare.set(true, profile: "two", config: &c)
        XCTAssertEqual(c.profile(named: "two")?.sharePlugins, true)
        XCTAssertEqual((json("two/settings.json")["env"] as? [String: String])?[PluginShare.envVar], box.root.path + "/base/plugins")
        XCTAssertEqual((json("two/settings.json")["env"] as? [String: String])?["KEEP"], "1", "other env keys stay")
        XCTAssertFalse(PluginShare.problems(c).isEmpty, "on/off lists differ until synced")

        let lines = PluginShare.sync(c)
        XCTAssertTrue(lines.contains { $0.contains("c@m") }, "c@m is installed and on in two: promoted to the base")
        let base = json("base/settings.json")["enabledPlugins"] as? [String: Bool]
        XCTAssertEqual(base, ["a@m": true, "b@m": false, "c@m": true])
        XCTAssertEqual(json("two/settings.json")["enabledPlugins"] as? [String: Bool], base, "gone@m (not installed) dropped")
        XCTAssertNotNil(json("two/settings.json")["extraKnownMarketplaces"])
        XCTAssertEqual(json("two/settings.json")["model"] as? String, "sonnet", "other keys untouched")
        XCTAssertNil(json("three/settings.json")["enabledPlugins"], "a profile that does not share is left alone")
        XCTAssertEqual(PluginShare.problems(c), [])

        try PluginShare.set(false, profile: "two", config: &c)
        XCTAssertNil((json("two/settings.json")["env"] as? [String: String])?[PluginShare.envVar])
        XCTAssertNil(c.profile(named: "two")?.sharePlugins)
    }

    func testBaseAndInvalidSettingsAreRefused() throws {
        var c = try setup()
        XCTAssertThrowsError(try PluginShare.set(true, profile: "base", config: &c))
        box.write("{not json", "three/settings.json")
        XCTAssertThrowsError(try PluginShare.set(true, profile: "three", config: &c))
        XCTAssertEqual(String(decoding: FileIO.read(box.root.appendingPathComponent("three/settings.json"))!, as: UTF8.self), "{not json")
    }

    func testInstallOutsideTheRootIsReported() throws {
        var c = try setup()
        try PluginShare.set(true, profile: "two", config: &c)
        PluginShare.sync(c)
        box.write(#"{"plugins":{"a@m":[{"installPath":"/elsewhere/a"}]}}"#, "base/plugins/installed_plugins.json")
        XCTAssertTrue(PluginShare.problems(c).contains { $0.contains("outside") })
    }
}
