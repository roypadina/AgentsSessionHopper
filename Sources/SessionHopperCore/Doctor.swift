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

        if let claude = Claude.locate(env) {
            let v = Shell.run(claude, ["--version"], timeout: 10).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty {
                add(.warn, "claude: \(env.tilde(claude)) (no version output)")
            } else if atLeast(v, minClaude) == false {
                add(.warn, "claude: \(env.tilde(claude)) \(v): \(minClaude) or newer needed. Older versions don't report background work at turn end, so a move can cut it off. Update: claude update")
            } else {
                add(.ok, "claude: \(env.tilde(claude)) \(v)")
            }
        } else {
            add(.fail, "claude not found on PATH. Install Claude Code first.")
        }
        let loose = unsupervised(ps: Shell.run("/bin/ps", ["-axo", "pid=,ppid=,command="], timeout: 10).stdout)
        if !loose.isEmpty {
            add(.warn, "\(loose.count) claude session(s) running without sessionhopper (pid \(loose.map(String.init).joined(separator: ", "))): they won't move. Restart each once: /exit, then `sessionhopper -c` in its folder (or `sessionhopper --resume <id>`)")
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
        add(.info, "thresholds: suggest \(Int(config.suggestThreshold))%, park \(Int(config.hardThreshold))% (\(config.parkBeforePaid ? "on" : "off")), move without asking: \(config.autoMove ? "on" : "off")\(config.moveNowAtHard ? ", at once past park" : "")")

        let now = FileIO.now()
        let claudePath = Claude.locate(env)
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

    /// `Stop.background_tasks` / `session_crons`, which keep a move from cutting work off.
    public static let minClaude = "2.1.145"

    /// nil when `version` has no leading x.y.z (e.g. "2.1.300 (Claude Code)" parses).
    static func atLeast(_ version: String, _ min: String) -> Bool? {
        func parts(_ s: String) -> [Int]? {
            let p = s.split(separator: " ").first?.split(separator: ".").map { Int($0) } ?? []
            return p.count >= 3 && !p.contains(nil) ? p.compactMap { $0 } : nil
        }
        guard let v = parts(version), let m = parts(min) else { return nil }
        return !v.lexicographicallyPrecedes(m)
    }

    /// Interactive `claude` processes with no `sessionhopper` above them (`ps -axo pid=,ppid=,command=`).
    /// A `claude` under another `claude` (a nested run) and print/subcommand runs are not sessions of their own.
    static func unsupervised(ps: String) -> [Int32] {
        var procs: [Int32: (ppid: Int32, cmd: String)] = [:]
        for line in ps.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
            procs[pid] = (ppid, String(f[2]))
        }
        func isClaude(_ cmd: String) -> Bool {
            let exe = cmd.split(separator: " ").first.map(String.init) ?? ""
            return (exe as NSString).lastPathComponent == "claude" || exe.contains("/claude/versions/")
        }
        let subcommands: Set<String> = ["mcp", "plugin", "plugins", "auth", "update", "doctor", "install", "setup-token"]
        let flags: Set<String> = ["-p", "--print", "--version", "-v", "--help", "-h"]
        return procs.compactMap { pid, p -> Int32? in
            guard isClaude(p.cmd) else { return nil }
            let args = p.cmd.split(separator: " ").dropFirst().map(String.init)
            if args.first.map(subcommands.contains) == true || args.contains(where: flags.contains) { return nil }
            var up = p.ppid
            var seen = 0
            while up > 1, let parent = procs[up], seen < 64 {
                if parent.cmd.contains("sessionhopper") || isClaude(parent.cmd) { return nil }
                up = parent.ppid
                seen += 1
            }
            return pid
        }.sorted()
    }
}
