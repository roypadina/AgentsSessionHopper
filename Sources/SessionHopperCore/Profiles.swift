import Foundation

public enum Profiles {
    /// `~/.claude` and `~/.claude-*` / `~/.claudeN` directories that look like Claude Code profiles.
    /// Read-only: lists directory names, opens nothing inside them.
    public static func discover(home: URL) -> [Profile] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: home.path)) ?? []
        return names.filter { $0 == ".claude" || $0.hasPrefix(".claude-") || ($0.hasPrefix(".claude") && $0.dropFirst(7).allSatisfy(\.isNumber)) }
            .sorted { ($0 == ".claude" ? "" : $0) < ($1 == ".claude" ? "" : $1) }
            .compactMap { entry -> Profile? in
                let dir = home.appendingPathComponent(entry)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
                // A profile has at least one of these; plain `.claude-something` tool folders don't.
                let markers = ["settings.json", "projects", ".claude.json", "sessions"]
                guard entry == ".claude" || markers.contains(where: { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) else { return nil }
                return Profile(name: name(forDir: entry), dir: dir.path, exportConfigDir: entry != ".claude")
            }
    }

    /// `.claude` → default, `.claude-work` → work, `.claude3` → claude3.
    public static func name(forDir entry: String) -> String {
        if entry == ".claude" { return "default" }
        if entry.hasPrefix(".claude-") { return String(entry.dropFirst(8)) }
        return String(entry.dropFirst())
    }

    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 32 && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// The transcript store every profile must share for a session to move between them.
    public static func projectsDir(_ config: HopperConfig, home: URL) -> URL {
        let base = config.profiles.first?.dir ?? home.appendingPathComponent(".claude").path
        return URL(fileURLWithPath: base).appendingPathComponent("projects").resolvingSymlinksInPath()
    }

    /// Items shared with the base profile when "share my setup" is on. `settings.json` is copied instead:
    /// Claude Code rewrites it by temp file + rename, which would replace a symlink.
    public static let sharedSetup = ["CLAUDE.md", "agents", "commands", "skills"]

    /// Creates a new profile directory next to `base`. Never overwrites anything that exists.
    /// `projects/` is always linked to the base's (required for hand-off). Returns what it did.
    public static func create(name: String, dir: URL, base: Profile?, home: URL, shareSetup: Bool) throws -> [String] {
        let fm = FileManager.default
        guard isValidName(name) else { throw HopperError("profile names use letters, digits, - and _ (max 32)") }
        var did: [String] = []
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let baseDir = URL(fileURLWithPath: base?.dir ?? home.appendingPathComponent(".claude").path)
        guard baseDir.standardizedFileURL != dir.standardizedFileURL else { return ["\(dir.path) is the base profile; nothing to link"] }

        let projects = baseDir.appendingPathComponent("projects")
        try fm.createDirectory(at: projects, withIntermediateDirectories: true)
        did.append(link(dir.appendingPathComponent("projects"), to: projects.resolvingSymlinksInPath()))
        if shareSetup {
            for item in sharedSetup where fm.fileExists(atPath: baseDir.appendingPathComponent(item).path) {
                did.append(link(dir.appendingPathComponent(item), to: baseDir.appendingPathComponent(item).resolvingSymlinksInPath()))
            }
            let settings = dir.appendingPathComponent("settings.json")
            let baseSettings = baseDir.appendingPathComponent("settings.json")
            if fm.fileExists(atPath: baseSettings.path), !fm.fileExists(atPath: settings.path) {
                try fm.copyItem(at: baseSettings, to: settings)
                did.append("copied settings.json")
            }
        }
        return did
    }

    private static func link(_ at: URL, to target: URL) -> String {
        let fm = FileManager.default
        if let dest = try? fm.destinationOfSymbolicLink(atPath: at.path) {
            return URL(fileURLWithPath: dest).resolvingSymlinksInPath() == target ? "\(at.lastPathComponent): already linked" : "\(at.lastPathComponent): links elsewhere, left alone"
        }
        if fm.fileExists(atPath: at.path) { return "\(at.lastPathComponent): exists, left alone" }
        do {
            try fm.createSymbolicLink(at: at, withDestinationURL: target)
            return "linked \(at.lastPathComponent)"
        } catch {
            return "\(at.lastPathComponent): could not link (\(error.localizedDescription))"
        }
    }

    /// Environment for running the unmodified `claude` under `profile`.
    public static func environment(for profile: Profile, base: [String: String]) -> [String: String] {
        var env = base
        env["CLAUDE_CONFIG_DIR"] = profile.exportConfigDir ? profile.dir : nil
        return env
    }

    /// What the user runs to log a profile in. Login always happens in Anthropic's own flow.
    public static func loginCommand(for profile: Profile, tilde: (String) -> String) -> String {
        profile.exportConfigDir ? "CLAUDE_CONFIG_DIR=\(tilde(profile.dir)) claude auth login" : "claude auth login"
    }
}
