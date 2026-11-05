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
        let subs = config.profiles.filter { !$0.isGateway }
        if env.vars["CLAUDE_CODE_OAUTH_TOKEN"].map({ !$0.isEmpty }) == true, subs.count > 1 {
            add(.info, "CLAUDE_CODE_OAUTH_TOKEN is set: it is used for \(subs[0].name) only. The other Claude profiles use their own stored token (sessionhopper profiles key <name>) or their own login.")
        }
        for p in config.profiles {
            let tag = "\(p.name) (\(env.tilde(p.dir)))"
            guard FileManager.default.fileExists(atPath: p.dir) else { add(.fail, "\(tag): directory missing"); continue }
            if p.isGateway {
                do { _ = try Gateway.key(p, env: env); add(.ok, "\(tag): \(p.kind ?? "") key found (\(Gateway.keySource(p, env: env)))") }
                catch { add(.fail, "\(tag): \(error)") }
            } else if let claudePath {
                let authEnv = Claude.authEnvironment(p, env: env)
                let status = Shell.run(claudePath, ["auth", "status"], timeout: 15, env: authEnv).status
                let via = (try? Gateway.key(p, env: env)) != nil ? " (its stored token)"
                    : authEnv["CLAUDE_CODE_OAUTH_TOKEN"] != nil ? " (CLAUDE_CODE_OAUTH_TOKEN of this environment)" : ""
                let why = !via.isEmpty ? "not logged in: \(via.dropFirst(2).dropLast()) was rejected (expired or revoked?)"
                    : "not logged in here (no login in its folder, no stored token\(Gateway.ownsEnvToken(p, env: env) ? ", CLAUDE_CODE_OAUTH_TOKEN not set in this environment" : ""))"
                add(status == 0 ? .ok : .warn, status == 0 ? "\(tag): logged in\(via)"
                    : "\(tag): \(why). Run: \(Profiles.loginCommand(for: p, tilde: env.tilde)), or store a setup-token: sessionhopper profiles key \(p.name) < tokenfile")
            }
            if let l = LimitStore.read(p.name, env.paths) {
                let age = Int((now - l.sampledAt) / 60)
                let pct = l.percent(now: now).map { "\(Int($0.rounded()))%" } ?? "reset since"
                add(.info, "\(p.name): last usage sample \(age) min ago, \(pct)")
            } else if p.isGateway {
                add(.info, "\(p.name): pay per use, no usage windows; it counts as full only after a 402 (out of credit), until its next \(p.resets ?? "daily") reset")
            } else {
                add(.warn, "\(p.name): no usage sample yet, so it counts as having room until a session on it reports (comes with the first status-line update)")
            }
            if HookInstaller.isInstalled(p) { add(.info, "\(p.name): hooks installed (sessions started without sessionhopper report usage too)") }
        }

        // An exported key overrides every profile's login: usage bills the key and the status line carries no `rate_limits`.
        // (CLAUDE_CODE_OAUTH_TOKEN is not one: it goes to the first Claude profile only, see `Gateway.applyClaudeToken`.)
        let keys = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"].filter { !(env.vars[$0] ?? "").isEmpty }
        if !keys.isEmpty {
            add(.warn, "\(keys.joined(separator: ", ")) set in this environment: sessions use it on every profile instead of the profile's login, report no usage limits, and hand-offs never trigger. Unset it to use your Claude logins")
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
        // Not required for a move, but without them the todo list and /rewind checkpoints stay behind.
        let base = config.profiles[0]
        for p in config.profiles.dropFirst() {
            // Only folders the base has: Claude Code moved task lists from `todos` to `tasks`, so one of them is gone.
            let used = ["todos", "tasks", "file-history"].filter { FileManager.default.fileExists(atPath: URL(fileURLWithPath: base.dir).appendingPathComponent($0).path) }
            let apart = notShared(used, dir: p.dir, base: base.dir)
            if !apart.isEmpty { add(.info, "\(p.name): \(apart.joined(separator: ", ")) not shared with \(base.name), so task lists and /rewind stay behind on a move. Share: sessionhopper profiles share \(p.name)") }
        }
        // One `sessions/` registry lets sessions on different accounts find each other (undocumented; may change with a Claude Code update).
        let others = config.profiles.dropFirst().filter { !$0.isGateway && $0.dir != base.dir }
        if !others.isEmpty {
            let off = Set(others.filter { !notShared(["sessions"], dir: $0.dir, base: base.dir).isEmpty }.map(\.name))
            add(off.isEmpty ? .ok : .info, "cross-account messaging (sessions/ shared with \(base.name)): "
                + others.map { "\($0.name) \(off.contains($0.name) ? "off" : "on")" }.joined(separator: ", ")
                + (off.isEmpty ? "" : ". Turn on: sessionhopper profiles share <name> (with no claude running on it)"))
        }
        let shell = Setup.shellKind(env.vars)
        add(.info, Setup.shellInstalled(shell, home: env.home, vars: env.vars)
            ? "\(shell.rawValue): `claude` runs through sessionhopper"
            : "\(shell.rawValue): no AgentsSessionHopper alias, so plain `claude` is supervised only if your own setup routes it. Start sessions with `sessionhopper`, or run: sessionhopper shell install")
        if config.suggestThreshold >= config.hardThreshold { add(.fail, "suggest threshold must be below the park threshold") }
        return out
    }

    /// Items of `dir` that do not resolve to the same folder as in `base`. Compares paths, not URLs:
    /// a real folder's URL ends in "/" and one reached through a symlink does not, so URLs never match.
    static func notShared(_ items: [String], dir: String, base: String) -> [String] {
        items.filter {
            URL(fileURLWithPath: dir).appendingPathComponent($0).resolvingSymlinksInPath().path
                != URL(fileURLWithPath: base).appendingPathComponent($0).resolvingSymlinksInPath().path
        }
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
