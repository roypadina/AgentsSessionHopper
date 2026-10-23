import Foundation
import SessionHopperCore

let env = HopperEnvironment.current()
var args = Array(CommandLine.arguments.dropFirst())

func say(_ s: String) { FileHandle.standardError.write(Data("\u{1B}[2m[sessionhopper]\u{1B}[0m \(s)\n".utf8)) }
func die(_ s: String) -> Never { say(s); exit(1) }
func out(_ s: String) { print(s) }

/// `--flag value` out of `args`, removing both.
func take(_ flag: String, from a: inout [String]) -> String? {
    guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
    let v = a[i + 1]
    a.removeSubrange(i...(i + 1))
    return v
}

func has(_ flag: String, in a: inout [String]) -> Bool {
    guard let i = a.firstIndex(of: flag) else { return false }
    a.remove(at: i)
    return true
}

func readStdin() -> Data { FileHandle.standardInput.readDataToEndOfFile() }

func pct(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "-" }

func ago(_ t: Double, now: Double) -> String {
    let m = Int((now - t) / 60)
    return m < 90 ? "\(m)m ago" : m < 48 * 60 ? "\(m / 60)h ago" : "\(m / 1440)d ago"
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

let usage = """
    sessionhopper: profiles for Claude Code. Run your own accounts side by side and, when one runs low,
    continue the same conversation on another (you confirm each move).

      sessionhopper [claude args...]            start a session on the first profile with room
      sessionhopper -P work [claude args...]    start on "work" (others stay fallbacks); --only work = strict
      sessionhopper --resume <id> | -c          adopt an existing session (bare --resume lists them)
      sessionhopper sessions [n]                resumable sessions in this directory
      sessionhopper switch [profile] [--now]    move this session at turn end (--session <id> from outside)
      sessionhopper hold on|off [--all]         never park or auto-move this session (or every session)
      sessionhopper status [--json]             profiles, last-known usage, live sessions
      sessionhopper profiles [list|import|add <name> [--dir D] [--no-share] [--no-login]
                              |remove <name>|order a,b,c|export-config-dir <name> on|off]
      sessionhopper login <profile>             run `claude auth login` for that profile
      sessionhopper config [suggest N|park-at N|park on|off|auto-move on|off]
      sessionhopper log [-n 20] [--json]        the switch log
      sessionhopper doctor                      check claude, logins, shared history, thresholds
      sessionhopper install-hooks --profile X   report usage from sessions started without sessionhopper
      sessionhopper uninstall-hooks --profile X undo install-hooks
      sessionhopper shim [claude args...]       for cmux/IDEs: interactive runs are supervised, the rest
                                              go straight to claude (or link the binary as *-shim)

    Not affiliated with Anthropic. It starts the unmodified `claude`, never reads your login or tokens,
    and makes no network requests.
    """

// MARK: - Subcommands

func hookCommand(_ a: [String]) -> Int32 {
    var a = a
    let profile = take("--profile", from: &a)
    if let text = HookHandler.handle(input: readStdin(), env: env, installedProfile: profile) { out(text) }
    return 0
}

func statusLineCommand(_ a: [String]) -> Int32 {
    var a = a
    let profile = take("--profile", from: &a)
    FileHandle.standardOutput.write(Data(StatusLineBridge.run(input: readStdin(), env: env, installedProfile: profile).utf8))
    return 0
}

func statusCommand(_ a: [String]) -> Int32 {
    var a = a
    let s = HopperSnapshot.load(env.paths, events: 5)
    if has("--json", in: &a) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        out(String(data: (try? enc.encode(s)) ?? Data(), encoding: .utf8) ?? "{}")
        return 0
    }
    if s.config.profiles.isEmpty { out("No profiles yet. Run: sessionhopper profiles import"); return 0 }
    out("Profiles (fallback order)")
    for (i, p) in s.config.profiles.enumerated() {
        let l = s.limits[p.name]
        let five = l?.fiveHour.flatMap { $0.isLive(now: s.now) ? $0.usedPercentage : nil }
        let week = l?.sevenDay.flatMap { $0.isLive(now: s.now) ? $0.usedPercentage : nil }
        var note = l.map { "sampled \(ago($0.sampledAt, now: s.now))" } ?? "no sample yet"
        if let p = s.percent(p.name), p >= s.config.suggestThreshold { note += ", near limit" }
        let n = s.sessions(on: p.name).count
        out("  \(i + 1). \(pad(p.name, 10)) \(pad(env.tilde(p.dir), 20)) 5h \(pad(pct(five), 5)) 7d \(pad(pct(week), 5)) \(note)\(n > 0 ? ", \(n) session\(n == 1 ? "" : "s")" : "")")
    }
    let c = s.config
    out("Hand-off: suggest at \(Int(c.suggestThreshold))%, park at \(Int(c.hardThreshold))% (\(c.parkBeforePaid ? "on" : "off")), move without asking: \(c.autoMove ? "on" : "off")")
    if !s.sessions.isEmpty {
        out("Sessions")
        for x in s.sessions {
            var state = x.busy ? "busy" : "idle"
            if x.held { state += ", held" }
            if let p = x.pending { state += ", moving to \(p.to == "-" ? "next with room" : p.to) at turn end" }
            else if let sug = x.suggestion, !sug.dismissed { state += ", suggest: \(HookHandler.suggestionText(sug).replacingOccurrences(of: "[sessionhopper] ", with: ""))" }
            out("  \(x.record.session.prefix(8))  \(pad(x.record.profile, 10)) \(env.tilde(x.record.cwd))  \(state)")
        }
    }
    if !s.events.isEmpty {
        out("Recent")
        s.events.forEach { out("  " + describe($0)) }
    }
    return 0
}

func describe(_ e: HopperEvent) -> String {
    let time = e.ts.count >= 16 ? String(e.ts.dropFirst(5).prefix(11)).replacingOccurrences(of: "T", with: " ") : e.ts
    let sid = e.session.map { String($0.prefix(8)) } ?? ""
    let move = [e.from, e.to].compactMap { $0 }.joined(separator: " -> ")
    let why = [e.trigger, e.source].compactMap { $0 }.joined(separator: ", ")
    return "\(time)  \(pad(e.type, 7)) \(sid)  \(move)\(why.isEmpty ? "" : "  (\(why))")"
}

func sessionsCommand(_ a: [String]) -> Int32 {
    let n = a.first.flatMap(Int.init) ?? 10
    let config = HopperConfig.load(env.paths)
    let cwd = FileManager.default.currentDirectoryPath
    let list = Transcripts.list(cwd: cwd, projects: Profiles.projectsDir(config, home: env.home),
                                live: Transcripts.liveIDs(config: config, paths: env.paths), limit: n)
    if list.isEmpty { out("No resumable sessions in \(env.tilde(cwd))."); return 1 }
    out("Resumable sessions in \(env.tilde(cwd)):")
    for i in list {
        let age = ago(i.modified.timeIntervalSince1970, now: Date().timeIntervalSince1970)
        out("  \(i.id)  \(pad(age, 8)) \(i.firstPrompt.prefix(70))")
    }
    out("\n  resume:  sessionhopper --resume <id>      newest:  sessionhopper -c")
    return 0
}

func sessionArg(_ a: inout [String]) -> String {
    if let s = take("--session", from: &a) { return s }
    if let s = env.currentSessionID { return s }
    die("not inside a sessionhopper session; pass --session <id> (see: sessionhopper status)")
}

func switchCommand(_ a: [String]) -> Int32 {
    var a = a
    let id = sessionArg(&a)
    let now = has("--now", in: &a)
    do {
        let s = try Control.requestMove(session: id, to: a.first, now: now, source: "cli", env: env)
        let dest = a.first ?? "the next profile with room"
        out(now ? "Moving session \(s.record.session.prefix(8)) to \(dest) now; Claude Code restarts there within a second."
                : "Session \(s.record.session.prefix(8)) moves to \(dest) when this turn ends and no background work is left.")
        return 0
    } catch { die("\(error)") }
}

func holdCommand(_ a: [String]) -> Int32 {
    var a = a
    let all = has("--all", in: &a)
    let explicit = take("--session", from: &a)
    guard let mode = a.first, ["on", "off"].contains(mode) else { die("usage: sessionhopper hold on|off [--all] [--session <id>]") }
    let id = all ? nil : (explicit ?? env.currentSessionID)
    if !all && id == nil { die("not inside a sessionhopper session; pass --session <id> or --all") }
    do {
        try Control.setHold(session: id, on: mode == "on", env: env)
        out(mode == "on" ? "Held: \(all ? "every session stays" : "this session stays") on its profile; no park, no automatic move. Past 100% Claude Code may bill extra usage if your plan allows it."
                         : "Hold removed.")
        return 0
    } catch { die("\(error)") }
}

func profilesCommand(_ a: [String]) -> Int32 {
    var a = a
    var config = HopperConfig.load(env.paths)
    let sub = a.isEmpty ? "list" : a.removeFirst()
    func save() { do { try config.save(env.paths) } catch { die("\(error)") } }
    switch sub {
    case "list":
        if config.profiles.isEmpty {
            let found = Profiles.discover(home: env.home)
            out(found.isEmpty ? "No profiles configured or found." : "No profiles configured. Found on disk (add them with `sessionhopper profiles import`):")
            found.forEach { out("  \(pad($0.name, 10)) \(env.tilde($0.dir))") }
        }
        for (i, p) in config.profiles.enumerated() {
            out("  \(i + 1). \(pad(p.name, 10)) \(pad(env.tilde(p.dir), 22)) \(p.exportConfigDir ? "CLAUDE_CONFIG_DIR set" : "CLAUDE_CONFIG_DIR unset (default profile)")")
        }
    case "import":
        let known = Set(config.profiles.map(\.dir))
        let new = Profiles.discover(home: env.home).filter { !known.contains($0.dir) }
        config.profiles += new
        save()
        out(new.isEmpty ? "Nothing new found." : "Added: " + new.map { "\($0.name) (\(env.tilde($0.dir)))" }.joined(separator: ", "))
        out("Nothing inside the profile folders was changed. Check sharing with: sessionhopper doctor")
    case "add":
        guard let name = a.first, !name.hasPrefix("-") else { die("usage: sessionhopper profiles add <name> [--dir D] [--no-share] [--no-login]") }
        a.removeFirst()
        guard config.profile(named: name) == nil else { die("profile '\(name)' exists") }
        let dir = take("--dir", from: &a).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? env.home.appendingPathComponent(".claude-\(name)")
        let share = !has("--no-share", in: &a)
        let login = !has("--no-login", in: &a)
        let base = config.profiles.first
        do {
            let did = try Profiles.create(name: name, dir: dir, base: base, home: env.home, shareSetup: share)
            did.forEach { out("  \($0)") }
        } catch { die("\(error)") }
        let p = Profile(name: name, dir: dir.path, exportConfigDir: dir.path != env.home.appendingPathComponent(".claude").path)
        config.profiles.append(p)
        save()
        out("Added profile \(name) (\(env.tilde(dir.path))).")
        if login { return runLogin(p) }
        out("Log it in with: sessionhopper login \(name)   (or: \(Profiles.loginCommand(for: p, tilde: env.tilde)))")
    case "remove":
        guard let name = a.first, config.profile(named: name) != nil else { die("usage: sessionhopper profiles remove <name>") }
        config.profiles.removeAll { $0.name == name }
        save()
        out("Removed \(name) from the list. Its folder and login are untouched.")
    case "order":
        guard let list = a.first else { die("usage: sessionhopper profiles order a,b,c") }
        do { config.profiles = try config.order(prefer: list.split(separator: ",").map(String.init), only: false) } catch { die("\(error)") }
        save()
        out("Order: " + config.profiles.map(\.name).joined(separator: ", "))
    case "export-config-dir":
        guard a.count == 2, let i = config.profiles.firstIndex(where: { $0.name == a[0] }), ["on", "off"].contains(a[1]) else {
            die("usage: sessionhopper profiles export-config-dir <name> on|off")
        }
        config.profiles[i].exportConfigDir = a[1] == "on"
        save()
        out("\(a[0]): CLAUDE_CONFIG_DIR is \(a[1] == "on" ? "set" : "left unset") when launching.")
    default:
        die("unknown: profiles \(sub)")
    }
    return 0
}

/// The unmodified `claude auth login`, in the foreground: login completes in Anthropic's own flow.
func runLogin(_ p: Profile) -> Int32 {
    out("Logging in \(p.name): \(Profiles.loginCommand(for: p, tilde: env.tilde))")
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = [env.claudeBin, "auth", "login"]
    proc.environment = Profiles.environment(for: p, base: env.vars)
    do { try proc.run() } catch { die("cannot start claude: \(error)") }
    proc.waitUntilExit()
    return proc.terminationStatus
}

func loginCommand(_ a: [String]) -> Int32 {
    guard let name = a.first, let p = HopperConfig.load(env.paths).profile(named: name) else { die("usage: sessionhopper login <profile>") }
    return runLogin(p)
}

func configCommand(_ a: [String]) -> Int32 {
    var c = HopperConfig.load(env.paths)
    if a.count == 2 {
        let v = a[1]
        switch a[0] {
        case "suggest": c.suggestThreshold = Double(v) ?? c.suggestThreshold
        case "park-at": c.hardThreshold = Double(v) ?? c.hardThreshold
        case "park": c.parkBeforePaid = v == "on"
        case "auto-move": c.autoMove = v == "on"
        default: die("unknown setting \(a[0])")
        }
        do { try c.save(env.paths) } catch { die("\(error)") }
    } else if !a.isEmpty {
        die("usage: sessionhopper config [suggest N|park-at N|park on|off|auto-move on|off]")
    }
    out("suggest at:          \(Int(c.suggestThreshold))%")
    out("park at:             \(Int(c.hardThreshold))%  (park before paid usage: \(c.parkBeforePaid ? "on" : "off"))")
    out("move without asking: \(c.autoMove ? "on" : "off")")
    return 0
}

func logCommand(_ a: [String]) -> Int32 {
    var a = a
    let json = has("--json", in: &a)
    let n = take("-n", from: &a).flatMap(Int.init) ?? 20
    let events = EventLog.read(env.paths, last: n)
    if json {
        events.forEach { e in
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            out(String(data: (try? enc.encode(e)) ?? Data(), encoding: .utf8) ?? "")
        }
    } else {
        if events.isEmpty { out("No hand-offs yet.") }
        events.forEach { out(describe($0)) }
    }
    return 0
}

func doctorCommand(_ a: [String]) -> Int32 {
    let checks = Doctor.run(env: env)
    for c in checks { out("\(pad(c.level.rawValue, 5)) \(c.message)") }
    return checks.contains { $0.level == .fail } ? 1 : 0
}

func hooksCommand(_ a: [String], install: Bool) -> Int32 {
    var a = a
    guard let name = take("--profile", from: &a) else {
        die("usage: sessionhopper \(install ? "install" : "uninstall")-hooks --profile <name>  (one profile, on purpose)")
    }
    guard let p = HopperConfig.load(env.paths).profile(named: name) else { die("unknown profile '\(name)'") }
    do {
        let did = install ? try HookInstaller.install(p, env: env) : try HookInstaller.uninstall(p, env: env)
        did.forEach { out("  \($0)") }
        out(install ? "Installed into \(env.tilde(p.dir))/settings.json. Undo with: sessionhopper uninstall-hooks --profile \(name)"
                    : "Removed from \(env.tilde(p.dir))/settings.json.")
        return 0
    } catch { die("\(error)") }
}

// MARK: - Launch

func launch(_ a: [String]) -> Int32 {
    var o = LaunchOptions()
    var i = 0
    var listOnly = false
    func value() -> String {
        guard i + 1 < a.count else { die("\(a[i]) needs a value") }
        i += 1
        return a[i]
    }
    while i < a.count {
        let x = a[i]
        switch x {
        case "-P", "--profile": o.prefer += value().split(separator: ",").map(String.init)
        case "--only": o.prefer += value().split(separator: ",").map(String.init); o.only = true
        case "-c", "--continue": o.continueLast = true
        case "--session-id": o.sessionID = value(); o.sessionIsNew = true
        case "-r", "--resume":
            // The id must be known before `claude` starts for the conversation to survive a move,
            // so a bare --resume lists instead of opening Claude Code's own picker.
            if i + 1 < a.count, !a[i + 1].hasPrefix("-") { o.sessionID = value() } else { listOnly = true }
        case "--":
            o.claudeArgs += a[(i + 1)...]
            i = a.count
            continue
        default: o.claudeArgs.append(x)
        }
        i += 1
    }
    if listOnly { return sessionsCommand([]) }
    return Supervisor(env: env, options: o, say: say).run()
}

// MARK: - Shim (cmux / IDE "Claude binary path")

/// Non-interactive `claude` calls that must reach the real CLI untouched (and never start a supervised session).
let passthroughCommands: Set<String> = [
    "agents", "attach", "auth", "auto-mode", "daemon", "doctor", "gateway", "import", "install", "logs", "mcp", "plugin",
    "plugins", "project", "respawn", "rm", "setup-token", "stop", "kill", "ultrareview", "update", "upgrade"
]
let passthroughFlags: Set<String> = [
    "-p", "--print", "-v", "--version", "-h", "--help", "--bg", "--background", "--cloud", "--fork-session", "--from-pr", "--remote-control"
]

/// Used as a tool's "Claude binary path": interactive launches become supervised sessions, everything else
/// (subcommands, `-p`, `--version`, and any `claude` started inside a session) runs the real `claude`.
func shimCommand(_ a: [String]) -> Int32 {
    let direct = env.currentSessionID != nil || a.first.map(passthroughCommands.contains) == true || a.contains(where: passthroughFlags.contains)
    guard direct else { return launch(a) }
    guard let claude = Claude.locate(env) else { die("claude not found on PATH") }
    let me = URL(fileURLWithPath: env.selfPath).resolvingSymlinksInPath().path
    guard URL(fileURLWithPath: claude).resolvingSymlinksInPath().path != me else { die("`claude` on PATH is this shim; point the shim at the real claude with SESSIONHOPPER_CLAUDE_BIN") }
    let argv: [UnsafeMutablePointer<CChar>?] = ([claude] + a).map { strdup($0) } + [nil]
    execv(claude, argv)
    die("cannot run \(claude): \(String(cString: strerror(errno)))")
}

let commands: [String: ([String]) -> Int32] = [
    "shim": shimCommand,
    "hook": hookCommand, "statusline": statusLineCommand, "status": statusCommand, "sessions": sessionsCommand,
    "switch": switchCommand, "hold": holdCommand, "profiles": profilesCommand, "login": loginCommand,
    "config": configCommand, "log": logCommand, "doctor": doctorCommand,
    "install-hooks": { hooksCommand($0, install: true) }, "uninstall-hooks": { hooksCommand($0, install: false) },
    "help": { _ in out(usage); return 0 }, "--help": { _ in out(usage); return 0 },
    "version": { _ in out("sessionhopper \(HopperInfo.version)"); return 0 }
]

// Invoked through a link named `*-shim` (e.g. ~/bin/sessionhopper-shim): shim mode, for tools that take one path.
if (CommandLine.arguments[0] as NSString).lastPathComponent.hasSuffix("-shim") { exit(shimCommand(args)) }
if let first = args.first, let run = commands[first] {
    exit(run(Array(args.dropFirst())))
}
exit(launch(args))
