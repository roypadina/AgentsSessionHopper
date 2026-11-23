import Foundation

/// One plugin set for every opted-in profile. Claude Code keeps installed plugins, marketplaces and their cache in
/// `<config dir>/plugins`; the documented `CLAUDE_CODE_PLUGIN_CACHE_DIR` moves that root. Opted-in profiles get it in
/// their own `settings.json` → `env`, pointing at the base profile's `plugins` folder, so every `claude` on them (also one
/// started without sessionhopper) installs, updates and loads from one place: versions cannot drift.
/// The on/off list stays per profile (`enabledPlugins` in each `settings.json`); `sync` makes it equal to the base's.
public enum PluginShare {
    public static let envVar = "CLAUDE_CODE_PLUGIN_CACHE_DIR"

    /// The profile whose plugins everyone uses: the one the sharing profiles already point at (so reordering the
    /// profiles does not move it), else the first Claude (non-gateway) profile.
    public static func base(_ config: HopperConfig) -> Profile? {
        let claude = config.profiles.filter { !$0.isGateway }
        for p in claude where p.sharePlugins == true {
            if let root = (settings(p)["env"] as? [String: Any])?[envVar] as? String,
               let b = claude.first(where: { $0.dir + "/plugins" == root && $0.name != p.name }) { return b }
        }
        return claude.first
    }

    public static func root(_ config: HopperConfig) -> String? { base(config).map { $0.dir + "/plugins" } }

    // Write through a symlinked settings.json instead of replacing the link (as HookInstaller).
    static func settingsURL(_ p: Profile) -> URL { URL(fileURLWithPath: p.dir).appendingPathComponent("settings.json").resolvingSymlinksInPath() }

    /// Opted-in Claude profiles other than the base.
    public static func sharing(_ config: HopperConfig) -> [Profile] {
        let b = base(config)?.name
        return config.profiles.filter { $0.sharePlugins == true && !$0.isGateway && $0.name != b }
    }

    // MARK: - settings.json

    /// Reads, changes and writes back one profile's `settings.json` (temp file + rename). A file that is not a JSON
    /// object is left alone. Throws when it cannot be written.
    static func editSettings(_ p: Profile, _ change: (inout [String: Any]) -> Void) throws {
        let url = settingsURL(p)
        let data = FileIO.read(url)
        guard var obj = data == nil ? [:] : FileIO.jsonObject(data) else {
            throw HopperError("\(url.path) is not a JSON object; left alone")
        }
        let before = NSDictionary(dictionary: obj)
        change(&obj)
        guard !before.isEqual(to: obj) else { return }
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileIO.write(out + Data("\n".utf8), to: url)
    }

    static func settings(_ p: Profile) -> [String: Any] { FileIO.jsonObject(FileIO.read(settingsURL(p))) ?? [:] }

    /// Turns sharing on or off for `p`: the env key in its `settings.json`, and the config flag. The profile's own
    /// `plugins` folder is left as it is (rollback = turn it off again). With `backupsDir`, a copy of `settings.json`
    /// is kept there first (the write reformats it); returns its path.
    @discardableResult
    public static func set(_ on: Bool, profile name: String, config: inout HopperConfig, backupsDir: URL? = nil) throws -> String? {
        guard let i = config.profiles.firstIndex(where: { $0.name == name }) else { throw HopperError("no profile named \(name)") }
        let p = config.profiles[i]
        guard !p.isGateway else { throw HopperError("\(name) runs on an API key; plugins are shared between Claude profiles") }
        guard let b = base(config), let root = root(config) else { throw HopperError("no Claude profile to share from") }
        guard p.name != b.name else { throw HopperError("\(name) is the base profile: the others share its plugins") }
        var backup: String?
        if let dir = backupsDir, let data = FileIO.read(settingsURL(p)), (settings(p)["env"] as? [String: Any])?[envVar] as? String != (on ? root : nil) {
            let url = dir.appendingPathComponent("\(p.name)-settings-\(Int(FileIO.now())).json")
            try FileIO.write(data, to: url)
            backup = url.path
        }
        try editSettings(p) { s in
            var env = s["env"] as? [String: Any] ?? [:]
            env[envVar] = on ? root : nil
            s["env"] = env.isEmpty ? nil : env
        }
        config.profiles[i].sharePlugins = on ? true : nil
        return backup
    }

    // MARK: - Enablement

    /// `name@marketplace` keys in the shared `installed_plugins.json`.
    static func installed(root: String) -> Set<String> {
        let obj = FileIO.jsonObject(FileIO.read(URL(fileURLWithPath: root + "/installed_plugins.json")))
        return Set((obj?["plugins"] as? [String: Any] ?? [:]).keys)
    }

    /// Makes `enabledPlugins` and `extraKnownMarketplaces` of every sharing profile equal to the base's. A plugin a
    /// profile turned on that the base lacks (installed from a session there) is first added to the base when it is
    /// installed, so nothing turned on disappears. Returns one line per profile changed.
    @discardableResult
    public static func sync(_ config: HopperConfig) -> [String] {
        guard let b = base(config), let root = root(config) else { return [] }
        let profiles = sharing(config)
        guard !profiles.isEmpty else { return [] }
        // An unreadable base file (bad JSON, caught mid-write) must not wipe everyone's list; only a missing one is empty.
        if let data = FileIO.read(settingsURL(b)), FileIO.jsonObject(data) == nil {
            return ["\(b.name): settings.json is not a JSON object; plugin on/off lists not synced"]
        }
        let have = installed(root: root)
        var baseOn = settings(b)["enabledPlugins"] as? [String: Any] ?? [:]
        var promoted: [String] = []
        for p in profiles {
            for (k, v) in settings(p)["enabledPlugins"] as? [String: Any] ?? [:]
            where baseOn[k] == nil && (v as? Bool) == true && have.contains(k) {
                baseOn[k] = true
                promoted.append(k)
            }
        }
        var lines: [String] = []
        if !promoted.isEmpty, (try? editSettings(b, { $0["enabledPlugins"] = baseOn })) != nil {
            lines.append("\(b.name): turned on \(promoted.sorted().joined(separator: ", ")) (installed and on in another profile)")
        }
        let market = settings(b)["extraKnownMarketplaces"]
        for p in profiles {
            let before = settings(p)
            let own = before["enabledPlugins"] as? [String: Any] ?? [:]
            let changed = Set(own.keys).union(baseOn.keys)
                .filter { !NSDictionary(dictionary: ["v": own[$0] ?? NSNull()]).isEqual(to: ["v": baseOn[$0] ?? NSNull()]) }
            do {
                try editSettings(p) { s in
                    s["enabledPlugins"] = baseOn
                    s["extraKnownMarketplaces"] = market
                }
            } catch { lines.append("\(p.name): \(error)"); continue }
            if !NSDictionary(dictionary: before).isEqual(to: settings(p)) {
                lines.append("\(p.name): plugin on/off list now equals \(b.name)'s" + (changed.isEmpty ? "" : " (changed: \(changed.sorted().joined(separator: ", ")))"))
            }
        }
        return lines
    }

    // MARK: - Checks

    /// Problems with sharing, for `doctor` and `plugins status`. Empty = fine.
    public static func problems(_ config: HopperConfig) -> [String] {
        guard let b = base(config), let root = root(config) else { return [] }
        var out: [String] = []
        let baseOn = NSDictionary(dictionary: settings(b)["enabledPlugins"] as? [String: Any] ?? [:])
        for p in sharing(config) {
            let env = settings(p)["env"] as? [String: Any]
            if env?[envVar] as? String != root { out.append("\(p.name): settings.json env \(envVar) is not \(root) (run: sessionhopper profiles share-plugins \(p.name))") }
            if !baseOn.isEqual(to: settings(p)["enabledPlugins"] as? [String: Any] ?? [:]) {
                out.append("\(p.name): its plugin on/off list differs from \(b.name)'s (run: sessionhopper plugins sync)")
            }
        }
        let obj = FileIO.jsonObject(FileIO.read(URL(fileURLWithPath: root + "/installed_plugins.json")))
        let outside = (obj?["plugins"] as? [String: Any] ?? [:]).values.flatMap { $0 as? [[String: Any]] ?? [] }
            .compactMap { $0["installPath"] as? String }.filter { !$0.hasPrefix(root + "/") }
        if !outside.isEmpty { out.append("\(outside.count) plugin install(s) recorded outside \(root)") }
        return out
    }

    // MARK: - Running plugin commands

    /// Runs `claude plugin <args>` once, on the base profile, under a lock in the shared root (5 profiles updating one
    /// marketplace clone at once fail with "File exists"), then syncs the on/off lists. Returns claude's exit code.
    public static func run(_ args: [String], env: HopperEnvironment) -> Int32 {
        let config = HopperConfig.load(env.paths)
        guard let b = base(config), let root = root(config) else { FileHandle.standardError.write(Data("no Claude profile to run plugin commands on\n".utf8)); return 127 }
        guard let claude = Claude.locate(env) else { FileHandle.standardError.write(Data("claude not found on PATH\n".utf8)); return 127 }
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let fd = open(root + "/.sessionhopper.lock", O_RDWR | O_CREAT, 0o600)
        defer { if fd >= 0 { close(fd) } }
        if fd >= 0 { _ = flock(fd, LOCK_EX) }
        let status = Claude.runInTerminal(claude, ["plugin"] + args, env: Profiles.environment(for: b, base: env.vars))
        sync(HopperConfig.load(env.paths))
        return status
    }
}
