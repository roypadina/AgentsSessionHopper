import Foundation

/// `sessionhopper doctor`: read-only checks. Runs `claude --version` and, per profile,
/// `claude auth status` (documented: exit 0 when logged in; https://code.claude.com/docs/en/cli-reference).
/// Reads no credentials itself.
public enum Doctor {
    public enum Level: String, Sendable { case ok, info, warn, fail }
    public struct Check: Sendable {
        public var level: Level
        public var message: String
    }

    public static func run(env: HopperEnvironment) -> [Check] {
        var out: [Check] = []
        func add(_ l: Level, _ m: String) { out.append(Check(level: l, message: m)) }

        let path = env.vars["PATH"]
        if let claude = Shell.which(env.claudeBin, path: path) {
            let v = Shell.run(claude, ["--version"], timeout: 10).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            add(v.isEmpty ? .warn : .ok, "claude: \(env.tilde(claude)) \(v.isEmpty ? "(no version output)" : v)")
        } else {
            add(.fail, "claude not found on PATH. Install Claude Code first.")
        }

        let probe = env.paths.root.appendingPathComponent(".doctor-probe")
        if (try? FileIO.write("ok", to: probe)) != nil {
            FileIO.remove(probe)
            add(.ok, "state dir writable: \(env.tilde(env.paths.root.path))")
        } else {
            add(.fail, "cannot write the state dir \(env.tilde(env.paths.root.path))")
        }

        let config = HopperConfig.load(env.paths)
        if config.profiles.isEmpty {
            let found = Profiles.discover(home: env.home)
            add(.warn, "no profiles configured. Found \(found.count) on disk: run `sessionhopper profiles import`")
            return out
        }
        add(.info, "thresholds: suggest \(Int(config.suggestThreshold))%, park \(Int(config.hardThreshold))% (\(config.parkBeforePaid ? "on" : "off")), move without asking: \(config.autoMove ? "on" : "off")")

        let now = FileIO.now()
        let claudePath = Shell.which(env.claudeBin, path: path)
        for p in config.profiles {
            let tag = "\(p.name) (\(env.tilde(p.dir)))"
            guard FileManager.default.fileExists(atPath: p.dir) else { add(.fail, "\(tag): directory missing"); continue }
            if let claudePath {
                let status = Shell.run(claudePath, ["auth", "status"], timeout: 15, env: Profiles.environment(for: p, base: env.vars)).status
                add(status == 0 ? .ok : .warn, status == 0 ? "\(tag): logged in" : "\(tag): not logged in. Run: \(Profiles.loginCommand(for: p, tilde: env.tilde))")
            }
            if let l = LimitStore.read(p.name, env.paths) {
                let age = Int((now - l.sampledAt) / 60)
                let pct = l.percent(now: now).map { "\(Int($0.rounded()))%" } ?? "reset since"
                add(.info, "\(p.name): last usage sample \(age) min ago, \(pct)")
            } else {
                add(.info, "\(p.name): no usage sample yet (comes with the first status-line update of a session)")
            }
            if HookInstaller.isInstalled(p) { add(.info, "\(p.name): hooks installed (sessions started without sessionhopper report usage too)") }
        }

        // Hand-off resumes the conversation under another profile: they must share one transcript store.
        let stores = Dictionary(grouping: config.profiles) {
            URL(fileURLWithPath: $0.dir).appendingPathComponent("projects").resolvingSymlinksInPath().path
        }
        if stores.count == 1 {
            add(.ok, "all profiles share one projects/ directory: sessions can move between them")
        } else {
            let base = Profiles.projectsDir(config, home: env.home).path
            let apart = config.profiles.filter {
                URL(fileURLWithPath: $0.dir).appendingPathComponent("projects").resolvingSymlinksInPath().path != base
            }.map(\.name)
            add(.warn, "projects/ not shared by: \(apart.joined(separator: ", ")). Sessions cannot move to or from them. Move their projects/ contents into \(env.tilde(base)), then replace the folder with a link to it.")
        }
        if config.suggestThreshold >= config.hardThreshold { add(.fail, "suggest threshold must be below the park threshold") }
        return out
    }
}
