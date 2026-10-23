import Foundation

/// `install-hooks` / `uninstall-hooks`: optional, explicit, per profile. Makes sessions started WITHOUT
/// `sessionhopper` on that profile report usage too, by putting our status line (chaining the user's own)
/// and a StopFailure hook into the profile's `settings.json`. Idempotent; uninstall restores the user's
/// status line. A copy of the file is kept in `backups/` before every write.
/// Supervised sessions never need this: they get the same through `--settings`.
public enum HookInstaller {
    static func settingsURL(_ profile: Profile) -> URL {
        // Write through a symlinked settings.json instead of replacing the link.
        URL(fileURLWithPath: profile.dir).appendingPathComponent("settings.json").resolvingSymlinksInPath()
    }

    public static func hookCommand(_ selfPath: String, profile: String) -> String {
        "\(FileIO.shellQuote(selfPath)) hook --profile \(profile)"
    }

    public static func statusLineCommand(_ selfPath: String, profile: String) -> String {
        "\(FileIO.shellQuote(selfPath)) statusline --profile \(profile)"
    }

    public static func isInstalled(_ profile: Profile) -> Bool {
        guard let obj = FileIO.jsonObject(FileIO.read(settingsURL(profile))) else { return false }
        return StatusLineBridge.isOurs((obj["statusLine"] as? [String: Any])?["command"] as? String, kind: "statusline")
    }

    @discardableResult
    public static func install(_ profile: Profile, env: HopperEnvironment) throws -> [String] {
        var (obj, did) = try load(profile, env: env)
        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        var groups = withoutOurs(hooks["StopFailure"])
        groups.append(["hooks": [["type": "command", "command": hookCommand(env.selfPath, profile: profile.name), "timeout": 10]]])
        hooks["StopFailure"] = groups
        obj["hooks"] = hooks
        did.append("StopFailure hook set")

        let existing = obj["statusLine"] as? [String: Any]
        if !StatusLineBridge.isOurs(existing?["command"] as? String, kind: "statusline") {
            if let existing {
                try FileIO.write(JSONSerialization.data(withJSONObject: existing, options: [.sortedKeys]), to: env.paths.savedStatusLine(profile.name))
                did.append("your status line is kept and still shown")
            } else {
                FileIO.remove(env.paths.savedStatusLine(profile.name))
            }
        }
        var ours: [String: Any] = ["type": "command", "command": statusLineCommand(env.selfPath, profile: profile.name)]
        for key in ["padding", "refreshInterval", "hideVimModeIndicator"] { ours[key] = existing?[key] }
        obj["statusLine"] = ours
        did.append("status line set")
        try save(obj, profile)
        return did
    }

    @discardableResult
    public static func uninstall(_ profile: Profile, env: HopperEnvironment) throws -> [String] {
        var (obj, did) = try load(profile, env: env)
        if var hooks = obj["hooks"] as? [String: Any] {
            let groups = withoutOurs(hooks["StopFailure"])
            hooks["StopFailure"] = groups.isEmpty ? nil : groups
            obj["hooks"] = hooks.isEmpty ? nil : hooks
            did.append("StopFailure hook removed")
        }
        if StatusLineBridge.isOurs((obj["statusLine"] as? [String: Any])?["command"] as? String, kind: "statusline") {
            let saved = FileIO.jsonObject(FileIO.read(env.paths.savedStatusLine(profile.name)))
            obj["statusLine"] = saved
            did.append(saved == nil ? "status line removed" : "your status line restored")
        }
        FileIO.remove(env.paths.savedStatusLine(profile.name))
        try save(obj, profile)
        return did
    }

    private static func load(_ profile: Profile, env: HopperEnvironment) throws -> ([String: Any], [String]) {
        let url = settingsURL(profile)
        guard FileManager.default.fileExists(atPath: profile.dir) else { throw HopperError("profile dir \(profile.dir) does not exist") }
        guard let data = FileIO.read(url), !data.isEmpty else { return ([:], []) }
        guard let obj = FileIO.jsonObject(data) else {
            throw HopperError("\(url.path) is not a JSON object; fix it first, nothing was changed")
        }
        let stamp = Int(FileIO.now())
        let backup = env.paths.backupsDir.appendingPathComponent("\(profile.name)-settings-\(stamp).json")
        try FileIO.write(data, to: backup)
        return (obj, ["backup: \(env.tilde(backup.path))"])
    }

    private static func save(_ obj: [String: Any], _ profile: Profile) throws {
        // Key order changes (JSONSerialization does not keep it); content does not.
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileIO.write(data + Data("\n".utf8), to: settingsURL(profile))
    }

    private static func withoutOurs(_ any: Any?) -> [[String: Any]] {
        (any as? [[String: Any]] ?? []).filter { group in
            !((group["hooks"] as? [[String: Any]]) ?? []).contains { StatusLineBridge.isOurs($0["command"] as? String, kind: "hook") }
        }
    }
}
