import Foundation
import SessionHopperCore

let env = HopperEnvironment.current()
var args = Array(CommandLine.arguments.dropFirst())

/// Dimmed tag only on a terminal (and never with NO_COLOR): callers' logs get plain text.
let colorErr = isatty(2) == 1 && (ProcessInfo.processInfo.environment["NO_COLOR"] ?? "").isEmpty
func say(_ s: String) { FileHandle.standardError.write(Data("\(colorErr ? "\u{1B}[2m[sessionhopper]\u{1B}[0m" : "[sessionhopper]") \(s)\n".utf8)) }
func die(_ s: String) -> Never { say(s); exit(1) }
func out(_ s: String) { print(s) }

/// Once per process, only on paths that start claude (never in hooks or the status line).
nonisolated(unsafe) var warnedStaleBin = false
func warnStaleClaudeBin() {
    guard let bad = env.staleClaudeBin, !warnedStaleBin else { return }
    warnedStaleBin = true
    say("SESSIONHOPPER_CLAUDE_BIN=\(bad) is missing — using the normal claude; unset it or restart the app that set it")
}

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
      sessionhopper --resume <id|name> | -c     adopt an existing session (bare --resume: numbered picker;
                                              a unique start of an id works too, 4+ characters)
      sessionhopper run [-P a,b] [--only] -- <claude -p args>  one non-interactive run (bots, services): the
                                              prompt on stdin; a limit failure retries the turn on the next profile
      sessionhopper sessions [n|all] [--all-dirs]  resumable sessions here (or everywhere), with names
      sessionhopper switch [profile] [--now]    move this session at turn end (--session <id> from outside)
      sessionhopper switch --cancel             drop this session's pending move (--session <id> from outside)
      sessionhopper switch <profile> --all [--now]  move every live session there (at turn end unless --now)
      sessionhopper hold on|off [--all]         never park or auto-move this session (or every session)
      sessionhopper status [--json]             profiles, last-known usage, live sessions
      sessionhopper refresh [profile...] [--stale]  fresh usage now: one tiny haiku `claude -p` per profile
                                              (--stale: only profiles with no sample in 6 h; the app does this by itself)
      sessionhopper profiles [list|import|add <name> [--dir D] [--no-share] [--no-login]
                              |remove <name>|order a,b,c|export-config-dir <name> on|off]
      sessionhopper profiles label <name> <text>|--clear  display name shown in the app and lists; the name itself never changes
      sessionhopper profiles share <name> [--dry-run]  link history, task lists, /rewind and setup to the first profile
                                              and the live-session list (messaging across accounts)
      sessionhopper profiles thresholds <name> <suggest %> <park %> | default  this profile's own move / park
                                              thresholds instead of the global ones (config suggest / park-at)
      sessionhopper profiles share-plugins <name...>|--all | unshare-plugins …  use the first profile's plugins folder
                                              (one plugin set, no drift); their on/off list follows it at each launch:
                                              turn plugins on/off on that profile or with `sessionhopper plugins enable|disable`
      sessionhopper plugins status | sync | <claude plugin args…>   e.g. `plugins update --all`, `plugins install x@m`:
                                              run once on the first profile, under a lock, then synced
                                              (Claude Code plugins; `sessionhopper plugin` installs sessionhopper's own skill)
      sessionhopper profiles pause <name> <30m|2h|1d|forever|5h-reset|weekly-reset> | profiles unpause <name>
                                              a paused profile counts as full: nothing starts or moves there, its sessions
                                              move off at turn end
      sessionhopper profiles priority <name> <n>|default  lower is preferred (Claude 1, API keys 10): equal priorities
                                              don't trade places before a limit; a freed-up better one is moved back to
      sessionhopper profiles add <name> --openrouter [--model opus=anthropic/claude-opus-5 ...] [--key-file F] [--resets daily|weekly|monthly]
                                              pay-per-use fallback: the same claude, billed to your OpenRouter key
      sessionhopper profiles add <name> --anthropic [--key-file F] [--resets ...]   billed to a Claude Console API key
      sessionhopper profiles add <name> --gateway <url> [--model opus=<name> ...] [--key-file F] [--resets ...]
                                              any Anthropic-compatible gateway (e.g. LiteLLM in front of an OpenAI key)
      sessionhopper profiles key <name> < file    store that profile's secret: its API key, or for a Claude
                                              profile on a server a `claude setup-token` (Keychain on macOS, private file on Linux)
      sessionhopper login <profile>             run `claude auth login` for that profile
      sessionhopper login <profile> --token     make a `claude setup-token` for it in a throwaway folder, paste it
                                              (several lines are fine), check it works and is not another profile's account
      sessionhopper mcp share on|off <profile...>  share one MCP login store (Atlassian, Slack, … logged in once) between
                                              profiles that run on a setup-token; /login and /logout are off there
      sessionhopper mcp status | mcp store <dir>|default  which profiles share, what the store holds (names only)
      sessionhopper alerts [status]               which alerts go where: Mac notification and/or ntfy, per profile
      sessionhopper alerts set <profile|all> <switch|no-room|usage-warning|usage-critical|paid|all> [mac on|off]
                              [ntfy on|off] [active-only on|off]  (active-only: usage alerts only while a session
                              here runs on that profile). Many sessions moving at once give one alert.
      sessionhopper alerts ntfy <server url> [<topic>] | ntfy off | ntfy token < file   where ntfy alerts go (topic on
                                              stdin keeps a public one out of shell history; off also forgets token + fallback)
      sessionhopper alerts ntfy fallback < file   a second topic URL, used only when the first post fails
      sessionhopper alerts test | alerts log [-n 20]
      sessionhopper shell [install|remove|status] [--shell zsh|bash|fish|tcsh]  make `claude` run through this
      sessionhopper shell link-shim             ~/.local/bin/sessionhopper-shim for cmux / JetBrains
      sessionhopper plugin [install|status] [--profile X]  the Claude skill in every profile
      sessionhopper config [suggest N|park-at N|park on|off|auto-move on|off|move-now on|off|wait on|off
                            |gateway last|order|manual|on-switch "<command>"|off]  (gateway: when API-key profiles are
                            used, default last; on-switch: runs on every move/limit/park with SESSIONHOPPER_EVENT, _FROM, _TO, _REASON, _FROM_LABEL, _TO_LABEL)
      sessionhopper config prompt [--file F | --reset]  the prompt a cut-off session resumes with
      sessionhopper config rules [--file F | --reset]   your own instructions, given to every session at its start
      sessionhopper delegate [--model M] [-P a,b] [--here] "<task>" [-- <claude args>]  one self-contained `claude -p`
                                              turn on another profile with room (skips profiles where that model is spent);
                                              prints the answer. For a session whose own account ran out of a model
      sessionhopper version | --version | -v    this tool's version (does not start claude)
      sessionhopper log [-n 20] [--json]        the switch log
      sessionhopper doctor                      check claude, logins, shared history, thresholds
      sessionhopper install-hooks --profile X   report usage from sessions started without sessionhopper
      sessionhopper uninstall-hooks --profile X undo install-hooks
      sessionhopper shim [claude args...]       for cmux/IDEs: interactive runs are supervised, the rest
                                              go straight to claude (or link the binary as *-shim)

    Not affiliated with Anthropic. It starts the unmodified `claude`, never reads your Claude login, and makes
    no network requests of its own (`refresh` runs `claude`, one small request per profile). A key or setup-token you store with `profiles key` is handed only to that profile's `claude`.
    With `mcp share` on, it also keeps the shared MCP store free of account logins and backs up its MCP logins (key names only shown).
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
    let s = HopperSnapshot.load(env.paths, home: env.home, events: 5)
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
        var note = l.map { $0.note(now: s.now) } ?? "no sample yet"
        if let pct = s.percent(p.name), pct >= s.config.suggest(p.name) { note += ", near limit" }
        let n = s.sessions(on: p.name).count
        out("  \(i + 1). \(pad(p.displayName != p.name ? "\(p.displayName) (name: \(p.name))" : p.name, 10)) \(pad(p.isGateway ? Gateway.kindName(p) : env.tilde(p.dir), 20)) 5h \(pad(pct(five), 5)) 7d \(pad(pct(week), 5)) \(note)\(n > 0 ? ", \(n) session\(n == 1 ? "" : "s")" : "")\(pausedNote(p))\(s.emails[p.name].map { "  \($0)" } ?? "")")
    }
    let c = s.config
    out("Hand-off: suggest at \(Int(c.suggestThreshold))%, park at \(Int(c.hardThreshold))% (\(c.parkBeforePaid ? "on" : "off")), move without asking: \(c.autoMove ? "on" : "off")")
    if !s.sessions.isEmpty {
        out("Sessions")
        for x in s.sessions {
            var state = x.busy ? "busy" : "idle"
            if x.held { state += ", held" }
            if let t = x.waitingUntil { state += ", parked, waits for a reset until \(ProfileLimits.clock(t))" }
            if let p = x.pending { state += ", moving to \(p.to == "-" ? "next with room" : p.to) at turn end" }
            else if let sug = x.suggestion, !sug.dismissed { state += ", suggest: \(HookHandler.suggestionText(sug).replacingOccurrences(of: "[sessionhopper] ", with: ""))" }
            out("  \(x.record.session.prefix(8))  \(pad(x.record.profile, 10)) \(s.names[x.id].map { "\($0)  " } ?? "")\(env.tilde(x.record.cwd))  \(state)")
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

/// `[n|all] [--all-dirs]`.
func sessionsCommand(_ a: [String]) -> Int32 {
    var a = a
    let allDirs = has("--all-dirs", in: &a)
    let n = a.first == "all" ? Int.max : a.first.flatMap(Int.init) ?? 10
    let list = resumable(limit: n, allDirs: allDirs)
    let cwd = FileManager.default.currentDirectoryPath
    if list.isEmpty { out("No resumable sessions in \(allDirs ? "any folder" : env.tilde(cwd))."); return 1 }
    out("Resumable sessions in \(allDirs ? "every folder" : env.tilde(cwd)):")
    list.forEach { out("  \($0.id)  " + row($0, allDirs: allDirs)) }
    out("\n  resume:  sessionhopper --resume <id>      newest:  sessionhopper -c")
    return 0
}

func resumable(limit: Int, allDirs: Bool) -> [Transcripts.Info] {
    let config = HopperConfig.load(env.paths)
    return Transcripts.list(cwd: FileManager.default.currentDirectoryPath, projects: Profiles.projectsDir(config, home: env.home),
                            live: Transcripts.liveIDs(config: config, paths: env.paths), limit: limit, allDirs: allDirs)
}

/// `age  [folder]  name - first prompt`.
func row(_ i: Transcripts.Info, allDirs: Bool) -> String {
    let age = ago(i.modified.timeIntervalSince1970, now: Date().timeIntervalSince1970)
    let dir = allDirs ? "[\(env.tilde(i.cwd ?? "?"))]  " : ""
    return "\(pad(age, 8)) \(dir)" + [i.title, i.firstPrompt].compactMap { $0 }.joined(separator: " - ").prefix(74)
}

/// Bare `--resume` in a terminal: the numbered picker. Returns the chosen id.
func pick(allDirs: Bool) -> String? {
    var cache: [Transcripts.Info] = []
    func rows(_ n: Int) -> [Transcripts.Info] {
        if cache.count < n { cache = resumable(limit: n, allDirs: allDirs) }
        return cache
    }
    // Ask for one more than a page, so the picker knows whether "m" has anything behind it.
    var known = rows(11).count
    let choice = Picker.choose(count: known, row: { i in
        if i + 1 >= known { known = rows(i + 11).count }
        return row(rows(i + 1)[i], allDirs: allDirs)
    }, read: { readLine() }, write: { FileHandle.standardError.write(Data($0.utf8)) })
    return choice.map { cache[$0].id }
}

func sessionArg(_ a: inout [String]) -> String {
    if let s = take("--session", from: &a) { return s }
    if let s = env.currentSessionID { return s }
    die("not inside a sessionhopper session; pass --session <id> (see: sessionhopper status)")
}

func switchCommand(_ a: [String]) -> Int32 {
    var a = a
    if has("--all", in: &a) {
        guard let to = a.first, HopperConfig.load(env.paths).profile(named: to) != nil else { die("usage: sessionhopper switch <profile> --all") }
        let now = has("--now", in: &a)
        let moving = Sessions.live(env.paths).filter { $0.record.profile != to }
        do {
            for s in moving { _ = try Control.requestMove(session: s.record.session, to: to, now: now, source: "cli", env: env) }
        } catch { die("\(error)") }
        out(moving.isEmpty ? "No session to move: every live session is on \(to) already."
            : "\(moving.count) session(s) move to \(to) " + (now ? "now." : "when their turn ends."))
        return 0
    }
    let id = sessionArg(&a)
    if has("--cancel", in: &a) {
        let short = (Sessions.find(id, env.paths)?.record.session ?? id).prefix(8)
        do {
            guard let p = try Control.cancelMove(session: id, env: env) else { out("Session \(short) has no pending move."); return 0 }
            let what = p.to == PendingMove.park ? "park" : "move to \(p.to == PendingMove.anywhere ? "the next profile with room" : p.to)"
            out("Cancelled: session \(short) won't \(what) at turn end."
                + (p.source == "engine" ? " The engine queued it and may queue it again; to keep this session where it is: sessionhopper hold on" : ""))
            return 0
        } catch { die("\(error)") }
    }
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
        let policy = Policy(config: config, limits: [:], now: 0)
        for (i, p) in config.profiles.enumerated() {
            out("  \(i + 1). \(pad(p.displayName != p.name ? "\(p.displayName) (name: \(p.name))" : p.name, 10)) priority \(policy.priority(p))  \(pad(env.tilde(p.dir), 22)) \(p.isGateway ? "\(Gateway.kindName(p)), pay per use, key: \(Gateway.keySource(p, env: env))" : p.exportConfigDir ? "CLAUDE_CONFIG_DIR set" : "CLAUDE_CONFIG_DIR unset (default profile)")\(Profiles.email(of: p, home: env.home).map { "  \($0)" } ?? "")\(pausedNote(p))")
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
        if has("--openrouter", in: &a) { return addGateway(name, Gateway.openRouter, &a, &config) }
        if has("--anthropic", in: &a) { return addGateway(name, Gateway.anthropic, &a, &config) }
        if a.contains("--gateway") { return addGateway(name, Gateway.custom, &a, &config) }
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
    case "share":
        let dry = has("--dry-run", in: &a)
        guard let name = a.first, let p = config.profile(named: name), let base = config.profiles.first else {
            die("usage: sessionhopper profiles share <name> [--dry-run]   (links history and setup to the first profile)")
        }
        do {
            try Setup.share(p, base: base, dryRun: dry).forEach { out("  \($0)") }
        } catch { die("\(error)") }
        if dry { out("Dry run: nothing changed. Run again without --dry-run to apply.") }
    case "remove":
        guard let name = a.first, config.profile(named: name) != nil else { die("usage: sessionhopper profiles remove <name>") }
        config.profiles.removeAll { $0.name == name }
        save()
        out("Removed \(name) from the list. Its folder and login are untouched.")
    case "label":
        guard a.count >= 2 else { die("usage: sessionhopper profiles label <name> <text>|--clear   (display name only; the profile name stays)") }
        guard let i = config.profiles.firstIndex(where: { $0.name == a[0] }) else { die("No profile named \(a[0]). See: sessionhopper profiles list") }
        let text = a[1] == "--clear" ? "" : a.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if config.labelClashes(text, for: a[0]) { die("\"\(text)\" is already another profile's name or label.") }
        config.profiles[i].label = text.isEmpty ? nil : text
        save()
        out("\(a[0]): " + (config.profiles[i].label.map { "label \"\($0)\"" } ?? "label cleared"))
    case "order":
        guard let list = a.first else { die("usage: sessionhopper profiles order a,b,c") }
        do { config.profiles = try config.order(prefer: list.split(separator: ",").map(String.init), only: false) } catch { die("\(error)") }
        save()
        out("Order: " + config.profiles.map(\.name).joined(separator: ", "))
    case "key":
        guard let name = a.first, let p = config.profile(named: name) else { die("usage: sessionhopper profiles key <profile> < file   (API key, or a Claude setup-token)") }
        if isatty(0) == 1 { say("paste the key, then Ctrl-D") }
        do {
            // A Claude profile's secret is a setup-token, which a terminal wraps over several lines.
            let raw = String(decoding: readStdin(), as: UTF8.self)
            out("\(name): key stored in \(try Gateway.storeKey(p.isGateway ? raw : try SetupToken.parse(raw), for: p, env: env))")
        } catch { die("\(error)") }
    case "thresholds":
        guard let i = config.profiles.firstIndex(where: { $0.name == a.first }),
              a.count == 2 && a[1] == "default" || a.count == 3 && Double(a[1]) != nil && Double(a[2]) != nil else {
            die("usage: sessionhopper profiles thresholds <name> <suggest %> <park %> | default   (default = the global ones)")
        }
        config.profiles[i].suggestThreshold = a.count == 3 ? Double(a[1]) : nil
        config.profiles[i].hardThreshold = a.count == 3 ? Double(a[2]) : nil
        save()
        out("\(a[0]): suggest at \(Int(config.suggest(a[0])))%, park at \(Int(config.hard(a[0])))%" + (a.count == 2 ? " (the global ones)" : ""))
    case "share-plugins", "unshare-plugins":
        let on = sub == "share-plugins"
        let names = a == ["--all"] ? PluginShare.base(config).map { b in config.profiles.filter { !$0.isGateway && $0.name != b.name }.map(\.name) } ?? [] : a
        guard !names.isEmpty else { die("usage: sessionhopper profiles \(sub) <name...>|--all") }
        // Save after each profile: a later failure must not leave an earlier one sharing without its config flag.
        var done: [String] = [], failed: [String] = []
        for n in names {
            do {
                if let b = try PluginShare.set(on, profile: n, config: &config, backupsDir: env.paths.backupsDir) { out("\(n): backup \(env.tilde(b))") }
                save(); done.append(n)
            } catch { failed.append("\(n): \(error)") }
        }
        PluginShare.sync(config).forEach(out)
        if !done.isEmpty {
            out(on ? "\(done.joined(separator: ", ")) now use \(PluginShare.base(config)?.name ?? "")'s plugins (\(PluginShare.root(config) ?? "")). Their own plugins folders are left as they are. Restart their sessions to load them."
                   : "\(done.joined(separator: ", ")) use their own plugins folders again (as they were when sharing started; update them: claude plugin update)")
        }
        if !failed.isEmpty { die(failed.joined(separator: "\n")) }
    case "pause":
        guard a.count == 2, let i = config.profiles.firstIndex(where: { $0.name == a[0] }) else {
            die("usage: sessionhopper profiles pause <name> <30m|2h|1d|forever|5h-reset|weekly-reset>   (undo: profiles unpause <name>)")
        }
        let now = Date().timeIntervalSince1970
        guard let until = Profile.pauseEnd(a[1], limits: LimitStore.read(a[0], env.paths), now: now) else {
            die("\(a[1]): use 30m, 2h, 1d, forever, 5h-reset or weekly-reset (a reset needs a usage sample with its reset time: sessionhopper refresh \(a[0]))")
        }
        config.profiles[i].pausedUntil = until
        save()
        out("\(a[0]): paused " + (until >= Profile.pausedForever ? "until you unpause it" : "until \(ProfileLimits.clock(until))")
            + ". Nothing starts or moves there; its sessions move off at their turn end. Undo: sessionhopper profiles unpause \(a[0])")
    case "unpause":
        guard a.count == 1, let i = config.profiles.firstIndex(where: { $0.name == a[0] }) else { die("usage: sessionhopper profiles unpause <name>") }
        config.profiles[i].pausedUntil = nil
        save()
        out("\(a[0]): in use again")
    case "priority":
        guard a.count == 2, let i = config.profiles.firstIndex(where: { $0.name == a[0] }), let n = Int(a[1]) ?? (a[1] == "default" ? 0 : nil) else {
            die("usage: sessionhopper profiles priority <name> <n>|default   (lower is preferred; Claude 1, API keys 10 by default)")
        }
        config.profiles[i].priority = a[1] == "default" ? nil : n
        save()
        let policy = Policy(config: config, limits: [:], now: 0)
        out("Priorities: " + config.profiles.map { "\($0.name) \(policy.priority($0))" }.joined(separator: ", "))
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

/// `profiles add <name> --openrouter|--anthropic|--gateway <url>`: no new folder; it runs in the first profile's
/// folder, so history is shared.
func addGateway(_ name: String, _ kind: String, _ a: inout [String], _ config: inout HopperConfig) -> Int32 {
    guard Profiles.isValidName(name), let base = config.profiles.first(where: { !$0.isGateway }) else {
        die("add your Claude profiles first (sessionhopper profiles import); the API-key profile goes last")
    }
    let url = take("--gateway", from: &a)
    if kind != Gateway.custom, url != nil { die("--gateway is its own kind: use it without --openrouter or --anthropic") }
    if kind == Gateway.custom, !(url.map(Gateway.validURL) ?? false) { die("--gateway takes the gateway's http(s) URL, e.g. --gateway http://localhost:4000") }
    var models: [String: String] = [:]
    while let m = take("--model", from: &a) {
        let kv = m.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { die("--model takes alias=name, e.g. opus=anthropic/claude-opus-5") }
        models[kv[0]] = kv[1]
    }
    let resets = take("--resets", from: &a)
    if let r = resets, !["daily", "weekly", "monthly"].contains(r) { die("--resets is daily, weekly or monthly") }
    let p = Profile(name: name, dir: base.dir, exportConfigDir: base.exportConfigDir, kind: kind,
                    keyFile: take("--key-file", from: &a), models: models.isEmpty ? nil : models, baseURL: url, resets: resets)
    config.profiles.append(p)
    do { try config.save(env.paths) } catch { die("\(error)") }
    out("Added \(name): \(Gateway.kindName(p)), pay per use, used only when no Claude profile has room. Runs in \(env.tilde(base.dir)).")
    if (try? Gateway.key(p, env: env)) == nil { out("Store its key: sessionhopper profiles key \(name) < keyfile   (key goes to \(Gateway.keySource(p, env: env)))") }
    return 0
}

/// `run [-P a,b] [--only] -- <claude args>`.
func runCommand(_ a: [String]) -> Int32 {
    warnStaleClaudeBin()
    var a = a
    let only = has("--only", in: &a)
    let prefer = (take("-P", from: &a) ?? take("--profile", from: &a)).map { $0.split(separator: ",").map(String.init) } ?? []
    if a.first == "--" { a.removeFirst() }
    let input = isatty(0) == 1 ? InputFeed(Data()) : InputFeed(reading: .standardInput)
    return OneShot.run(env: env, prefer: prefer, only: only, args: a, stdin: input, say: say)
}

/// The unmodified `claude auth login`, in the foreground: login completes in Anthropic's own flow.
func runLogin(_ p: Profile) -> Int32 {
    out("Logging in \(p.name): \(Profiles.loginCommand(for: p, tilde: env.tilde))")
    guard let claude = Claude.locate(env) else { die("claude not found on PATH") }
    return Claude.runInTerminal(claude, ["auth", "login"], env: Profiles.environment(for: p, base: env.vars))
}

func loginCommand(_ a: [String]) -> Int32 {
    var a = a
    let token = has("--token", in: &a)
    guard let name = a.first, let p = HopperConfig.load(env.paths).profile(named: name) else { die("usage: sessionhopper login <profile> [--token]") }
    if p.isGateway { die("\(name) runs on an API key: sessionhopper profiles key \(name) < keyfile") }
    if token { return tokenLogin(p) }
    if p.mcpShare == true { die("\(name) shares MCP logins, so it runs on a setup-token: sessionhopper login \(name) --token") }
    return runLogin(p)
}

/// Terminal state while a pasted token is read with echo off; put back on Ctrl-C too.
nonisolated(unsafe) var savedTerminal: termios?

/// Every line typed until an empty one, not echoed.
func readHiddenLines() -> String {
    var tty = termios()
    if isatty(0) == 1, tcgetattr(0, &tty) == 0 {
        savedTerminal = tty
        var quiet = tty
        quiet.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(0, TCSAFLUSH, &quiet)
        signal(SIGINT) { _ in if var t = savedTerminal { tcsetattr(0, TCSAFLUSH, &t) }; _exit(130) }
    }
    defer {
        if var t = savedTerminal { tcsetattr(0, TCSAFLUSH, &t); savedTerminal = nil; signal(SIGINT, SIG_DFL); print("") }
    }
    var text = ""
    while let line = readLine(), !line.trimmingCharacters(in: .whitespaces).isEmpty { text += line }
    return text
}

/// `login <profile> --token`: a setup-token made in a throwaway folder (no profile's login is touched), checked with
/// one tiny request before it replaces the stored one, then compared with the other profiles' usage.
func tokenLogin(_ p: Profile) -> Int32 {
    guard let claude = Claude.locate(env) else { die("claude not found on PATH") }
    let config = HopperConfig.load(env.paths)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ash-login-\(UUID().uuidString)")
    do { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { die("\(error)") }
    // `die` exits at once, so a `defer` would never run: the pasted token must not stay behind.
    func cleanup() {
        try? FileManager.default.removeItem(at: tmp)
        #if os(macOS)
        McpShare.forgetThrowaway(tmp.path, env: env)
        #endif
    }
    func fail(_ s: String) -> Never { cleanup(); die(s) }
    defer { cleanup() }
    let who = Profiles.email(of: p, home: env.home) ?? "the account for \(p.displayName)"
    out("=== Profile \(p.displayName): sign in as \(who) ===")
    out("1. Open the link below in a PRIVATE browser window and sign in as \(who).")
    out("   (A window already signed in to another account makes a token that works but bills that account.)")
    out("2. Copy the token it prints at the end (starts with \(SetupToken.prefix)).")
    var e = env.vars
    for k in ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "DISABLE_LOGIN_COMMAND", "DISABLE_LOGOUT_COMMAND"] { e[k] = nil }
    e["CLAUDE_CONFIG_DIR"] = tmp.path
    e[McpShare.envVar] = tmp.path
    let status = Claude.runInTerminal(claude, ["setup-token"], env: e)
    guard status == 0 else { fail("claude setup-token failed (exit \(status)). Nothing stored.") }

    out("Paste the token (hidden). It may span several lines; then press Enter on an empty line.")
    let token: String
    do { token = try SetupToken.parse(readHiddenLines()) } catch { fail("\(error)") }

    out("Checking the token works (one tiny request)...")
    let file = tmp.appendingPathComponent("token")
    do { try Gateway.writePrivate(Data(token.utf8), to: file) } catch { fail("\(error)") }
    var trial = p
    trial.keyFile = file.path
    let stop = Terminator()
    let check = UsageRefresh.run([trial], env: env, stop: stop)
    guard check.ok else { fail("Claude rejected the token (\(check.lines.joined(separator: "; "))). Nothing stored; run this again.") }
    do { out("Stored in \(try Gateway.storeKey(token, for: p, env: env)).") } catch { fail("\(error)") }

    let others = config.profiles.filter { !$0.isGateway && $0.name != p.name }
    if !others.isEmpty {
        out("Checking it is not another profile's account (one tiny request each)...")
        UsageRefresh.run(others, env: env, stop: stop)
        if let mine = LimitStore.read(p.name, env.paths) {
            let twins = others.filter { o in LimitStore.read(o.name, env.paths).map { SetupToken.sameAccount(mine, $0) } ?? false }
            if !twins.isEmpty {
                say("WARNING: \(p.displayName) has the same usage and reset times as \(twins.map(\.displayName).joined(separator: ", ")): it is probably the SAME Claude account. Sign out in the browser (or use a private window) and run: sessionhopper login \(p.name) --token")
                return 2
            }
        }
    }
    out("OK: \(p.displayName) runs on its token." + (p.mcpShare == true ? " It shares MCP logins with the other shared profiles."
        : " To share MCP logins with other token profiles: sessionhopper mcp share on \(p.name)"))
    return 0
}

/// "  paused until 14:00" / "  paused until you unpause it", or "".
func pausedNote(_ p: Profile) -> String {
    guard let u = p.pausedUntil, u > Date().timeIntervalSince1970 else { return "" }
    return u >= Profile.pausedForever ? "  paused until you unpause it" : "  paused until \(ProfileLimits.clock(u))"
}

/// `plugins sync | status | <claude plugin args…>`: one plugin set for the profiles that share it (`PluginShare`).
func pluginsCommand(_ a: [String]) -> Int32 {
    let config = HopperConfig.load(env.paths)
    switch a.first ?? "status" {
    case "sync":
        let lines = PluginShare.sync(config)
        out(lines.isEmpty ? "plugin on/off lists already match" : lines.joined(separator: "\n"))
        return 0
    case "status":
        let sharing = PluginShare.sharing(config)
        out("base: \(PluginShare.base(config)?.name ?? "-") (\(PluginShare.root(config) ?? "-"))")
        out("sharing: " + (sharing.isEmpty ? "none (sessionhopper profiles share-plugins <name...>|--all)" : sharing.map(\.name).joined(separator: ", ")))
        let p = PluginShare.problems(config)
        out(p.isEmpty ? "no problems" : p.map { "problem: " + $0 }.joined(separator: "\n"))
        return p.isEmpty ? 0 : 1
    default:
        // Anything else is a `claude plugin` command, run once on the base profile (install, update, uninstall, …).
        return PluginShare.run(a, env: env)
    }
}

/// `alerts [status] | set … | ntfy … | test | log | deliver <id>`.
func alertsCommand(_ a: [String]) -> Int32 {
    var a = a
    var config = HopperConfig.load(env.paths)
    func save() { do { try config.save(env.paths) } catch { die("\(error)") } }
    func onOff(_ flag: String) -> Bool? {
        guard let v = take(flag, from: &a) else { return nil }
        guard v == "on" || v == "off" else { die("\(flag) takes on or off") }
        return v == "on"
    }
    let sub = a.isEmpty ? "status" : a.removeFirst()
    switch sub {
    case "status": break
    case "set":
        guard a.count >= 2 else { die("usage: sessionhopper alerts set <profile|all> <kind|all> [mac on|off] [ntfy on|off] [active-only on|off]") }
        let who = a.removeFirst(), what = a.removeFirst()
        let profile = who == "all" ? AlertSettings.everyProfile : who
        if profile != AlertSettings.everyProfile, config.profile(named: profile) == nil { die("No profile named \(who). See: sessionhopper profiles list") }
        let kinds = what == "all" ? AlertKind.allCases : [AlertKind(rawValue: what) ?? { die("kinds: \(AlertKind.allCases.map(\.rawValue).joined(separator: ", ")), all") }()]
        let mac = onOff("mac"), ntfy = onOff("ntfy"), active = onOff("active-only")
        guard mac != nil || ntfy != nil || active != nil, a.isEmpty else { die("say what to change: mac on|off, ntfy on|off, active-only on|off") }
        for k in kinds { config.alerts.set(profile, k, mac: mac, ntfy: ntfy, activeOnly: active) }
        save()
        if ntfy == true, !config.alerts.ntfyOn { say("ntfy is not set up yet: sessionhopper alerts ntfy <server url> <topic>") }
    case "ntfy":
        if a.first == "off" {
            // The token and the fallback topic go too: a public topic name is a secret.
            config.alerts.ntfyServer = nil
            config.alerts.ntfyTopic = nil
            save()
            Gateway.deleteKey(Alerts.tokenEntry, env: env)
            Gateway.deleteKey(Alerts.fallbackEntry, env: env)
            break
        }
        if a.first == "fallback" {
            if isatty(0) == 1 { say("paste the fallback topic URL (https://ntfy.sh/<topic>), then Ctrl-D") }
            let url = String(decoding: readStdin(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard Gateway.validURL(url), Alerts.splitTopicURL(url) != nil else { die("that is not a topic URL like https://ntfy.sh/<topic>") }
            do { out("ntfy fallback stored in \(try Gateway.storeKey(url, for: Alerts.fallbackEntry, env: env))") } catch { die("\(error)") }
            return 0
        }
        if a.first == "token" {
            if isatty(0) == 1 { say("paste the ntfy access token, then Ctrl-D") }
            do { out("ntfy token stored in \(try Gateway.storeKey(String(decoding: readStdin(), as: UTF8.self), for: Alerts.tokenEntry, env: env))") } catch { die("\(error)") }
            return 0
        }
        // The topic may come on stdin, so a public one stays out of `ps` and shell history.
        if a.count == 1, isatty(0) == 0 { a.append(String(decoding: readStdin(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard a.count == 2, Gateway.validURL(a[0]), Alerts.validTopic(a[1]) else {
            die("usage: sessionhopper alerts ntfy <server url, e.g. https://ntfy.sh> <topic> (or the topic on stdin) | off | token < file | fallback < file")
        }
        config.alerts.ntfyServer = a[0].hasSuffix("/") ? String(a[0].dropLast()) : a[0]
        config.alerts.ntfyTopic = a[1]
        save()
    case "test":
        let r = Alerts.test(env: env)
        out("Test alert written; the app shows it as a Mac notification.")
        if r.ntfy {
            let status = Alerts.sendNtfy(r, env: env)
            out("ntfy: " + (status.map { (200..<300).contains($0) ? "sent (HTTP \($0))" : "refused (HTTP \($0))" } ?? "no answer"))
            return status.map { (200..<300).contains($0) } == true ? 0 : 1
        }
        out("ntfy: not set up (sessionhopper alerts ntfy <server url> <topic>)")
        return 0
    case "log":
        let n = take("-n", from: &a).flatMap(Int.init) ?? 20
        for r in Alerts.read(env.paths, last: n) {
            out("\(r.ts)  \(pad(r.kind, 14)) \(pad(r.profile, 10)) \([r.mac ? "mac" : nil, r.ntfy ? "ntfy" : nil].compactMap { $0 }.joined(separator: "+"))  \(r.title)")
        }
        return 0
    case "deliver":
        // Started detached by the engine for one alert.
        guard let id = a.first, let r = Alerts.read(env.paths).last(where: { $0.id == id }), r.ntfy else { return 1 }
        return Alerts.sendNtfy(r, env: env).map { (200..<300).contains($0) } == true ? 0 : 1
    default:
        die("usage: sessionhopper alerts [status|set …|ntfy …|test|log]")
    }
    let s = config.alerts
    out("ntfy: " + (s.ntfyOn ? "\(s.ntfyServer ?? "")/\(s.ntfyTopic ?? "")" + ((try? Gateway.key(Alerts.tokenEntry, env: env)) != nil ? " (with an access token)" : "") : "not set up"))
    out("\(pad("", 16)) " + AlertKind.allCases.map { pad($0.rawValue, 16) }.joined())
    for name in [AlertSettings.everyProfile] + config.profiles.map(\.name) {
        let shown = AlertKind.kinds(gateway: config.profile(named: name)?.isGateway)
        let cells = AlertKind.allCases.map { k -> String in
            guard shown.contains(k) else { return pad("-", 16) }
            let e = s.effective(name, k)
            let ch = [e.mac ? "mac" : nil, e.ntfy ? "ntfy" : nil].compactMap { $0 }.joined(separator: "+")
            return pad((ch.isEmpty ? "off" : ch) + (k == .usageWarning || k == .usageCritical ? (e.activeOnly ? " (active)" : "") : ""), 16)
        }
        out(pad(name == AlertSettings.everyProfile ? "all (default)" : name, 16) + " " + cells.joined())
    }
    return 0
}

/// `mcp share on|off <profile...>`, `mcp status`, `mcp store <dir>|default`.
func mcpCommand(_ a: [String]) -> Int32 {
    var config = HopperConfig.load(env.paths)
    func save() { do { try config.save(env.paths) } catch { die("\(error)") } }
    switch a.first ?? "status" {
    case "share":
        guard a.count >= 3, ["on", "off"].contains(a[1]) else { die("usage: sessionhopper mcp share on|off <profile...>") }
        for name in a.dropFirst(2) {
            guard let i = config.profiles.firstIndex(where: { $0.name == name }) else { die("No profile named \(name). See: sessionhopper profiles list") }
            if config.profiles[i].isGateway { die("\(name) runs on an API key; only Claude profiles use MCP logins") }
            config.profiles[i].mcpShare = a[1] == "on" ? true : nil
        }
        save()
    case "store":
        guard a.count == 2 else { die("usage: sessionhopper mcp store <dir>|default") }
        // Absolute, so the store (and its Keychain name) is the same from every folder.
        config.mcpStore = a[1] == "default" ? nil : URL(fileURLWithPath: (a[1] as NSString).expandingTildeInPath).standardizedFileURL.path
        save()
    case "status": break
    default: die("usage: sessionhopper mcp [status|share on|off <profile...>|store <dir>|default]")
    }
    McpShare.statusLines(config, env: env).forEach(out)
    return 0
}

func configCommand(_ a: [String]) -> Int32 {
    var c = HopperConfig.load(env.paths)
    if a.first == "prompt" { return promptCommand(Array(a.dropFirst()), &c) }
    if a.first == "rules" { return rulesCommand(Array(a.dropFirst()), &c) }
    if a.count == 2 {
        let v = a[1]
        switch a[0] {
        case "suggest": c.suggestThreshold = Double(v) ?? c.suggestThreshold
        case "park-at": c.hardThreshold = Double(v) ?? c.hardThreshold
        case "park": c.parkBeforePaid = v == "on"
        case "auto-move": c.autoMove = v == "on"
        case "move-now": c.moveNowAtHard = v == "on"
        case "wait": c.waitForReset = v == "on"
        case "gateway": c.gatewayUse = v
        case "on-switch": c.onSwitch = v == "off" ? nil : v
        default: die("unknown setting \(a[0])")
        }
        do { try c.save(env.paths) } catch { die("\(error)") }
    } else if !a.isEmpty {
        die("usage: sessionhopper config [suggest N|park-at N|park on|off|auto-move on|off|move-now on|off|wait on|off|gateway last|order|manual|on-switch <cmd>|off]")
    }
    out("suggest at:          \(Int(c.suggestThreshold))%")
    out("park at:             \(Int(c.hardThreshold))%  (park before paid usage: \(c.parkBeforePaid ? "on" : "off"))")
    for p in c.profiles where p.suggestThreshold != nil || p.hardThreshold != nil {
        out("  \(pad(p.name, 16)) own: suggest \(Int(c.suggest(p.name)))%, park \(Int(c.hard(p.name)))%")
    }
    out("move without asking: \(c.autoMove ? "on" : "off")")
    out("move/park at once past park threshold: \(c.moveNowAtHard ? "on" : "off")")
    out("all full, wait for a reset: \(c.waitForReset ? "on" : "off")")
    out("pay-per-use profiles: \(c.gatewayUse) (\(["last": "only after every Claude subscription is full", "order": "by list order", "manual": "only when asked for"][c.gatewayUse] ?? ""))")
    out("continue prompt:     \(c.continuePrompt == nil ? "built-in" : "your own") (sessionhopper config prompt)")
    out("on switch:           \(c.onSwitch ?? "off")")
    return 0
}

/// Shows the continue prompt; `--file F` sets your own, `--reset` goes back to the built-in one.
/// `config rules [--file F | --reset]`: the user's own instructions for every supervised session.
func rulesCommand(_ a: [String], _ c: inout HopperConfig) -> Int32 {
    if a == ["--reset"] {
        c.sessionRules = nil
    } else if a.count == 2, a[0] == "--file" {
        guard let text = try? String(contentsOfFile: (a[1] as NSString).expandingTildeInPath, encoding: .utf8) else { die("cannot read \(a[1])") }
        c.sessionRules = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    } else if !a.isEmpty {
        die("usage: sessionhopper config rules [--file F | --reset]")
    }
    if !a.isEmpty { do { try c.save(env.paths) } catch { die("\(error)") } }
    out(c.sessionRules.map { "session rules (given to every session at its start; new sessions and resumes pick them up):\n\n" + $0 }
        ?? "no session rules. Add: sessionhopper config rules --file rules.md")
    return 0
}

/// `delegate [--model M] [-P a,b] [--here] <task…> [-- <claude args>]`: one `claude -p` turn on another profile with room
/// (not this session's, unless --here), skipping profiles where that model is spent. The task may come on stdin.
func delegateCommand(_ a: [String]) -> Int32 {
    warnStaleClaudeBin()
    var a = a
    var extra: [String] = []
    if let i = a.firstIndex(of: "--") { extra = Array(a[(i + 1)...]); a = Array(a[..<i]) }
    let usage = "usage: sessionhopper delegate [--model M] [-P a,b] [--here] \"<self-contained task>\" [-- <claude args>]   (or the task on stdin)"
    var model: String?
    if let i = a.firstIndex(where: { $0.hasPrefix("--model=") }) { model = String(a.remove(at: i).dropFirst(8)) }
    if a.contains("--model") { guard let m = take("--model", from: &a), !m.hasPrefix("-") else { die(usage) }; model = m }
    let here = has("--here", in: &a)
    let named = take("-P", from: &a) ?? take("--profile", from: &a)
    // Anything else flag-like before the task is a typo, not task text: claude's own flags go after `--`.
    if let bad = a.first(where: { $0.hasPrefix("-") && !$0.contains(where: \.isWhitespace) }) { die("unknown option \(bad). \(usage)") }
    let config = HopperConfig.load(env.paths)
    let current = env.vars["SESSIONHOPPER_PROFILE"]
    // Pay-per-use profiles only when named with -P: an agent following session rules must not spend credit unasked.
    var prefer = named.map { $0.split(separator: ",").map(String.init) } ?? config.profiles.filter { !$0.isGateway }.map(\.name)
    if !here, let current { prefer.removeAll { $0 == current } }
    guard !prefer.isEmpty else { die("no other profile to delegate to") }
    var task = a.joined(separator: " ")
    if task.isEmpty, isatty(0) == 0 { task = String(decoding: readStdin(), as: UTF8.self) }
    guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { die(usage) }
    let args = ["-p"] + (model.map { ["--model", $0] } ?? []) + extra
    return OneShot.run(env: env, prefer: prefer, only: true, args: args, stdin: InputFeed(Data(task.utf8)), say: say)
}

func promptCommand(_ a: [String], _ c: inout HopperConfig) -> Int32 {
    if a == ["--reset"] {
        c.continuePrompt = nil
    } else if a.count == 2, a[0] == "--file" {
        guard let text = try? String(contentsOfFile: (a[1] as NSString).expandingTildeInPath, encoding: .utf8) else { die("cannot read \(a[1])") }
        c.continuePrompt = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    } else if !a.isEmpty {
        die("usage: sessionhopper config prompt [--file F | --reset]")
    }
    if !a.isEmpty { do { try c.save(env.paths) } catch { die("\(error)") } }
    out(c.continuePrompt == nil ? "continue prompt: built-in" : "continue prompt: your own (back to the built-in one: sessionhopper config prompt --reset)")
    out("placeholders: {reason} {jobs} {crons} {from} {to}; \"[sessionhopper] \" is always put in front")
    out("")
    out(c.continuePrompt ?? LaunchPlan.defaultContinuePrompt)
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
    warnStaleClaudeBin()
    var o = LaunchOptions()
    var i = 0
    var listOnly = false
    var picker = false
    var allDirs = false
    var listArgs: [String] = []
    func value() -> String {
        guard i + 1 < a.count else { die("\(a[i]) needs a value") }
        i += 1
        return a[i]
    }
    while i < a.count {
        let x = a[i]
        switch x {
        case "-P", "--profile", "--account": o.prefer += value().split(separator: ",").map(String.init)
        case "--only": o.prefer += value().split(separator: ",").map(String.init); o.only = true
        case "-c", "--continue": o.continueLast = true
        case "--session-id": o.sessionID = value(); o.sessionIsNew = true
        case "-r", "--resume":
            // The id must be known before `claude` starts for the conversation to survive a move,
            // so a bare --resume shows our own picker (or list) instead of Claude Code's.
            if i + 1 < a.count, !a[i + 1].hasPrefix("-") { o.sessionID = value() } else { picker = true }
        case "--all-dirs": allDirs = true
        case "--sessions", "--list":
            listOnly = true
            if i + 1 < a.count, a[i + 1] == "all" || Int(a[i + 1]) != nil { listArgs = [value()] }
        case "--":
            o.claudeArgs += a[(i + 1)...]
            i = a.count
            continue
        default: o.claudeArgs.append(x)
        }
        i += 1
    }
    if picker, !listOnly, isatty(0) == 1, isatty(2) == 1 {
        guard let id = pick(allDirs: allDirs) else { return 1 }
        o.sessionID = id
    } else if picker || listOnly {
        return sessionsCommand(listArgs + (allDirs ? ["--all-dirs"] : []))
    }
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
    // Sessions started before 1.18.1 call `<shim> hook|statusline`: answer them here, never as a paid `claude` run.
    if a.first == "hook" { return hookCommand(Array(a.dropFirst())) }
    if a.first == "statusline" { return statusLineCommand(Array(a.dropFirst())) }
    if a.first == "alerts", a.dropFirst().first == "deliver" { return alertsCommand(Array(a.dropFirst())) }
    warnStaleClaudeBin()
    let direct = env.currentSessionID != nil || a.first.map(passthroughCommands.contains) == true || a.contains(where: passthroughFlags.contains)
    // In a session on the shared MCP store, a login would land in that store and a logout would delete everyone's MCP logins.
    if McpShare.inSharedSession(env), a.first == "setup-token" || (a.first == "auth" && a.count > 1 && ["login", "logout"].contains(a[1])) {
        die("claude \(a.prefix(2).joined(separator: " ")) is blocked in a session that shares MCP logins. Log a profile in with: sessionhopper login <profile> --token")
    }
    guard direct else { return launch(a) }
    guard let claude = Claude.locate(env) else { die("claude not found on PATH") }
    let me = URL(fileURLWithPath: env.selfPath).resolvingSymlinksInPath().path
    guard URL(fileURLWithPath: claude).resolvingSymlinksInPath().path != me else { die("`claude` on PATH is this shim; point the shim at the real claude with SESSIONHOPPER_CLAUDE_BIN") }
    let argv: [UnsafeMutablePointer<CChar>?] = ([claude] + a).map { strdup($0) } + [nil]
    execv(claude, argv)
    die("cannot run \(claude): \(String(cString: strerror(errno)))")
}

/// `shell install|remove|status [--shell zsh|bash|fish|tcsh] [--force]`, `shell link-shim`.
func shellCommand(_ a: [String]) -> Int32 {
    var a = a
    let force = has("--force", in: &a)
    let kind = take("--shell", from: &a).map { v in Setup.ShellKind(rawValue: v == "csh" ? "tcsh" : v) ?? { die("unknown shell \(v): zsh, bash, fish or tcsh") }() }
        ?? Setup.shellKind(env.vars)
    let cli = URL(fileURLWithPath: env.selfPath).resolvingSymlinksInPath().path
    do {
        switch a.first ?? "status" {
        case "install": out(try Setup.installShell(kind, cli: cli, home: env.home, vars: env.vars, force: force))
        case "remove": out(try Setup.removeShell(kind, home: env.home, vars: env.vars))
        case "link-shim": out(try Setup.linkShim(cli: cli, home: env.home))
        case "status":
            out("\(kind.rawValue) (\(env.tilde(Setup.rcFile(kind, home: env.home, vars: env.vars).path))): " + (Setup.shellInstalled(kind, home: env.home, vars: env.vars) ? "claude runs through sessionhopper" : "not set up"))
            out("line: \(Setup.aliasLine(kind, cli: cli))")
        default: die("usage: sessionhopper shell [install|remove|status|link-shim] [--shell zsh|bash|fish|tcsh] [--force]")
        }
    } catch { die("\(error)") }
    return 0
}

/// `plugin install|status [--profile X]`: the agents-session-hopper skill in each profile.
func pluginCommand(_ a: [String]) -> Int32 {
    var a = a
    let only = take("--profile", from: &a)
    let profiles = HopperConfig.load(env.paths).profiles.filter { only == nil || $0.name == only }
    guard !profiles.isEmpty else { die("no such profile") }
    var rc: Int32 = 0
    for p in profiles {
        switch a.first ?? "status" {
        case "install":
            do { out(try Setup.installPlugin(p, env: env)) } catch { out("\(error)"); rc = 1 }
        case "status":
            let s = Setup.pluginInstalled(p, env: env)
            out("\(pad(p.name, 10)) \(s == true ? "installed" : s == false ? "not installed (sessionhopper plugin install)" : "unknown (claude not found)")")
        default: die("usage: sessionhopper plugin [install|status] [--profile X]   (Claude Code plugins: sessionhopper plugins …)")
        }
    }
    return rc
}

func refreshCommand(_ a: [String]) -> Int32 {
    var a = a
    let stale = has("--stale", in: &a)
    let config = HopperConfig.load(env.paths)
    var ps = a.isEmpty ? config.profiles : config.profiles.filter { a.contains($0.name) }
    if let bad = a.first(where: { n in !config.profiles.contains { $0.name == n } }) { die("no profile named \(bad)") }
    if stale {
        let due = Set(UsageRefresh.due(config, limits: LimitStore.all(config, env.paths), now: Date().timeIntervalSince1970).map(\.name))
        ps = ps.filter { due.contains($0.name) }
    }
    let r = UsageRefresh.run(ps, env: env, stop: Terminator())
    r.lines.forEach(out)
    return r.ok ? 0 : 1
}

func versionCommand(_: [String]) -> Int32 { out("sessionhopper \(HopperInfo.version)"); return 0 }

let commands: [String: ([String]) -> Int32] = [
    "shim": shimCommand, "run": runCommand,
    "hook": hookCommand, "statusline": statusLineCommand, "status": statusCommand, "refresh": refreshCommand, "sessions": sessionsCommand,
    "switch": switchCommand, "hold": holdCommand, "profiles": profilesCommand, "login": loginCommand, "mcp": mcpCommand, "alerts": alertsCommand, "delegate": delegateCommand, "plugins": pluginsCommand,
    "config": configCommand, "shell": shellCommand, "plugin": pluginCommand, "log": logCommand, "doctor": doctorCommand,
    "install-hooks": { hooksCommand($0, install: true) }, "uninstall-hooks": { hooksCommand($0, install: false) },
    "help": { _ in out(usage); return 0 }, "--help": { _ in out(usage); return 0 },
    "version": versionCommand, "--version": versionCommand, "-v": versionCommand
]

// Invoked through a link named `*-shim` (e.g. ~/bin/sessionhopper-shim): shim mode, for tools that take one path.
if (CommandLine.arguments[0] as NSString).lastPathComponent.hasSuffix("-shim") { exit(shimCommand(args)) }
// VS Code extension, `claudeCode.claudeProcessWrapper`: called as `sessionhopper <bundled claude> <flags>`.
if PanelWrapper.isWrapperCall(args) { exit(PanelWrapper.run(env: env, args: args, say: say)) }
if let first = args.first, let run = commands[first] {
    exit(run(Array(args.dropFirst())))
}
exit(launch(args))
