import Foundation

/// The Claude Code VS Code extension's `claudeCode.claudeProcessWrapper`: set it to `sessionhopper` and the
/// extension runs `sessionhopper <its bundled claude> <flags>` for every panel conversation (and `auth status`).
///
/// A panel conversation becomes a supervised session like one in the terminal: it starts on the profile the
/// policy picks, shows in `status` and the app with live usage (`rate_limit_event`), and moves to another profile
/// the same way (usage limit, "move without asking" at a turn end, a better priority freeing up, or a confirmed
/// `switch`). A move restarts `claude --resume <id>` on the new profile behind the extension's back: the wrapper
/// replays the extension's own startup requests, swallows their answers, and for a turn that failed on a limit
/// sends the same message again, so the panel just carries on.
public enum PanelWrapper {
    /// `<absolute path to an executable named claude> ...`: how the extension calls a wrapper.
    public static func isWrapperCall(_ args: [String]) -> Bool {
        guard let first = args.first, first.hasPrefix("/"), (first as NSString).lastPathComponent == "claude" else { return false }
        return FileManager.default.isExecutableFile(atPath: first)
    }

    /// The environment and args for `claude` on profile `p`.
    public static func launch(_ p: Profile, args: [String], env: HopperEnvironment) -> (args: [String], env: [String: String]) {
        var e = Profiles.environment(for: p, base: env.vars)
        if p.isGateway, let key = try? Gateway.key(p, env: env) { e.merge(Gateway.environment(p, key: key)) { _, new in new } }
        Gateway.applyClaudeToken(&e, p, env: env)
        e["SESSIONHOPPER_PROFILE"] = p.name
        return (p.isGateway ? Gateway.modelArgs(args, p) : args, e)
    }

    /// Profiles a panel session may use: gateways only with their key.
    static func usable(_ config: HopperConfig, env: HopperEnvironment, excluding: Set<String> = []) -> [Profile] {
        config.profiles.filter { !excluding.contains($0.name) && (!$0.isGateway || Claude.isLoggedIn($0, env: env) == true) }
    }

    /// The profile for this start: by policy (keeping the session's last profile among equals); with every profile
    /// full, the first Claude profile (claude then shows its own usage-limit message in the panel).
    public static func pick(_ config: HopperConfig, env: HopperEnvironment, session: String?, now: Double) -> Profile? {
        let list = usable(config, env: env)
        let policy = Policy(config: config, limits: LimitStore.all(config, env.paths), now: now)
        return policy.pick(list, current: EventLog.lastServed(session: session, env.paths)) ?? list.first { !$0.isGateway }
    }

    public static func run(env: HopperEnvironment, args: [String], say: @escaping (String) -> Void) -> Int32 {
        let claude = args[0]
        let rest = Array(args.dropFirst())
        let config = HopperConfig.load(env.paths)
        let session = OneShot.sessionID(rest)
        guard let p = pick(config, env: env, session: session, now: FileIO.now()) else { return exec(claude, rest, env.vars) }
        // Non-conversation calls (`auth status --json`, MCP helpers): run on the chosen profile, untouched.
        guard rest.contains("--input-format"), rest.contains("stream-json") else {
            let (a, e) = launch(p, args: rest, env: env)
            return exec(claude, a, e)
        }
        return PanelSession(claude: claude, args: rest, profile: p, session: session, env: env, say: say).run()
    }

    static func exec(_ claude: String, _ args: [String], _ env: [String: String]) -> Int32 {
        let argv: [UnsafeMutablePointer<CChar>?] = ([claude] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        execve(claude, argv, envp)
        return 127
    }

    /// `--resume <id>` in place of the caller's `--resume` / `--session-id` / `--continue` / `--fork-session`.
    public static func resumeArgs(_ args: [String], session: String) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if ["--resume", "-r", "--session-id"].contains(a) { i += 2; continue }
            if a.hasPrefix("--resume=") || a.hasPrefix("--session-id=") || ["--continue", "-c", "--fork-session"].contains(a) { i += 1; continue }
            out.append(a)
            i += 1
        }
        return out + ["--resume", session]
    }
}

/// One panel conversation: the `claude` behind it, swapped for another profile when the session moves.
final class PanelSession: @unchecked Sendable {
    private let claude: String
    private let args: [String]
    private let env: HopperEnvironment
    private let say: (String) -> Void
    private var profile: Profile
    private var session: String?
    private let lock = NSLock()
    private var child: Process?
    private var childIn: FileHandle?
    /// What the extension sent at startup (`initialize`, later `set_*` requests): replayed to a new `claude`.
    private var setup: [(id: String, line: String)] = []
    private var lastUserLine: String?
    /// Answers to replayed requests, and the echo/init of a replayed start, are not the extension's business.
    private var swallowIDs: Set<String> = []
    private var swallowInit = false
    private var swallowEcho = false
    private var stdinClosed = false
    /// A turn is running (a user message was sent, its result has not come).
    private var busy = false
    private var finished = false
    /// One move decision at a time (turn ends on the reader, idle checks on their own thread).
    private let moveLock = NSLock()
    private let stop = Terminator()

    init(claude: String, args: [String], profile: Profile, session: String?, env: HopperEnvironment, say: @escaping (String) -> Void) {
        self.claude = claude
        self.args = args
        self.profile = profile
        self.session = session
        self.env = env
        self.say = say
    }

    private var files: SessionFiles? { lock.sync { session }.map { env.paths.session($0) } }
    /// The profile now in use (the idle watcher may change it).
    private var current: Profile { lock.sync { profile } }

    func run() -> Int32 {
        guard spawn(args) else { return 127 }
        if session != nil { publish() }
        log(type: "run", from: nil, to: profile.name, trigger: session == nil ? "start" : "resume")
        Thread.detachNewThread { [self] in pumpStdin() }
        Thread.detachNewThread { [self] in watchIdle() }
        defer { if let f = files { [f.record, f.busy, f.pending, f.ctl, f.suggest, f.suggestShown].forEach(FileIO.remove) } }
        while true {
            guard let out = lock.sync({ child?.standardOutput as? Pipe }) else { break }
            var held: [String] = []   // output of a turn that is failing on a limit
            var pending = Data()
            var swapped = false
            while !swapped, case let d = out.fileHandleForReading.availableData, !d.isEmpty {
                pending.append(d)
                while !swapped, let nl = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...nl)
                    swapped = handle(line, held: &held)
                }
            }
            if swapped { continue }
            // Ended because an idle move replaced it: read the new one.
            if lock.sync({ child?.standardOutput as? Pipe }) !== out { continue }
            if !pending.isEmpty { emit(String(decoding: pending, as: UTF8.self)) }
            held.forEach(emit)
            break
        }
        lock.sync { finished = true }
        let p = lock.sync { child }
        p?.waitUntilExit()
        stop.child = nil
        guard let p else { return 1 }
        return p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
    }

    // MARK: claude -> extension

    /// One line from `claude`. Returns true when the session moved to a new `claude` (stop reading the old one).
    private func handle(_ line: String, held: inout [String]) -> Bool {
        let obj = FileIO.jsonObject(Data(line.utf8))
        let type = obj?["type"] as? String
        if type == "control_response", let r = obj?["response"] as? [String: Any], let id = r["request_id"] as? String,
           lock.sync({ swallowIDs.remove(id) != nil }) { return false }
        if type == "system", obj?["subtype"] as? String == "init" {
            if let s = obj?["session_id"] as? String, lock.sync({ session == nil ? { session = s; return true }() : false }) { publish() }
            if lock.sync({ let s = swallowInit; swallowInit = false; return s }) { return false }
        }
        if type == "user", lock.sync({ let s = swallowEcho; swallowEcho = false; return s }) { return false }

        if type == "rate_limit_event", let info = obj?["rate_limit_info"] as? [String: Any] {
            let p = current
            if !p.isGateway, let l = OneShot.limits(info, now: FileIO.now()) { try? LimitStore.write(l, profile: p.name, env.paths) }
            if info["status"] as? String == "rejected" { held.append(line); return false }
        }
        if !held.isEmpty, type != "result" { held.append(line); return false }
        guard type == "result" else { emit(line); return false }

        // A turn ended.
        lock.sync { busy = false }
        if let f = files { FileIO.remove(f.busy) }
        var a = OneShot.Attempt()
        held.forEach { a.read(line: $0, now: FileIO.now()) }
        a.read(line: line, now: FileIO.now())
        let failure = OneShot.classify(a, now: FileIO.now())
        switch failure {
        case .limit, .credits, .login:
            let p = current
            OneShot.markFull(p, failure, attempt: a, paths: env.paths, now: FileIO.now())
            let why = failure == .login ? "login" : failure == .credits ? "credits" : "limit"
            if let next = nextProfile(excluding: [p.name]), moveLock.sync({ move(to: next, trigger: why, replayTurn: true) }) {
                held = []
                return true
            }
            say("\(p.name) cannot go on (\(why)) and no profile has room")
        default: break
        }
        held.forEach(emit)
        held = []
        emit(line)
        return moveLock.sync { turnEnd() }
    }

    /// Like the terminal supervisor: an idle session acts on a confirmed move, or a policy move, without waiting
    /// for another turn.
    private func watchIdle() {
        while true {
            Thread.sleep(forTimeInterval: 2)
            let (done, idle) = lock.sync { (finished || stdinClosed, !busy && session != nil) }
            if done { return }
            if idle, moveLock.try() {
                _ = turnEnd()
                moveLock.unlock()
            }
        }
    }

    /// At a turn end: a confirmed move, else the policy (auto-move, a better priority freeing up, suggestions).
    private func turnEnd() -> Bool {
        guard let f = files else { return false }
        let config = HopperConfig.load(env.paths)
        let cur = current
        if let req = FileIO.decode(PendingMove.self, from: f.ctl) ?? FileIO.decode(PendingMove.self, from: f.pending) {
            let to = req.to == PendingMove.anywhere ? nextProfile(excluding: [cur.name]) : config.profile(named: req.to)
            guard let to, to.name != cur.name else { FileIO.remove(f.ctl); FileIO.remove(f.pending); return false }
            // Kept until it happens: a message that arrived meanwhile defers it to the next turn end or idle check.
            guard move(to: to, trigger: req.trigger, replayTurn: false) else { return false }
            FileIO.remove(f.ctl)
            FileIO.remove(f.pending)
            return true
        }
        let held = FileIO.exists(f.hold) || FileIO.exists(env.paths.holdAll)
        let order = PanelWrapper.usable(config, env: env)
        let policy = Policy(config: config, limits: LimitStore.all(config, env.paths), now: FileIO.now())
        switch policy.evaluate(current: cur, order: order, held: held) {
        case .autoMove(let to, _):
            if let p = config.profile(named: to) { return move(to: p, trigger: "auto", replayTurn: false) }
        case .suggest(let to, let pct):
            let old = FileIO.decode(Suggestion.self, from: f.suggest)
            if old?.to != to || old?.dismissed != true {
                try? FileIO.encode(Suggestion(from: cur.name, to: to, percent: pct, reason: "threshold"), to: f.suggest)
            }
        case .park, .none: break
        }
        return false
    }

    private func nextProfile(excluding: Set<String>) -> Profile? {
        let config = HopperConfig.load(env.paths)
        let policy = Policy(config: config, limits: LimitStore.all(config, env.paths), now: FileIO.now())
        return policy.pick(PanelWrapper.usable(config, env: env, excluding: excluding))
    }

    // MARK: moving

    /// Ends this `claude` and resumes the conversation on `to`, replaying the extension's startup requests.
    /// False when it cannot move now: no session id yet, or (outside a re-run) a message is being handled, which
    /// would be lost with the old `claude`.
    // shortcut: waits for the old claude to exit without draining its stdout; fine unless it prints >64 KB after SIGTERM.
    @discardableResult
    private func move(to: Profile, trigger: String, replayTurn: Bool) -> Bool {
        lock.lock()
        guard let s = session, replayTurn || !busy else { lock.unlock(); return false }
        let from = profile
        if let old = child, old.isRunning {
            try? childIn?.close()
            kill(old.processIdentifier, SIGTERM)
            old.waitUntilExit()
        }
        profile = to
        let ok = spawnLocked(PanelWrapper.resumeArgs(args, session: s))
        if ok {
            // claude announces each turn with system/init; only a re-run turn already had its own.
            swallowInit = replayTurn
            for (id, line) in setup {
                swallowIDs.insert(id)
                try? childIn?.write(contentsOf: Data((line + "\n").utf8))
            }
            if replayTurn, let u = lastUserLine {
                swallowEcho = args.contains("--replay-user-messages")
                try? childIn?.write(contentsOf: Data((u + "\n").utf8))
            }
            if stdinClosed { try? childIn?.close() }
        }
        lock.unlock()
        if let f = files { FileIO.remove(f.suggest); if replayTurn { FileIO.touch(f.busy) } }
        publish()
        log(type: "switch", from: from.name, to: to.name, trigger: trigger)
        say("moved this conversation from \(from.name) to \(to.name) (\(trigger))")
        return ok
    }

    @discardableResult
    private func spawn(_ a: [String]) -> Bool { lock.sync { spawnLocked(a) } }

    private func spawnLocked(_ a: [String]) -> Bool {
        let (cargs, cenv) = PanelWrapper.launch(profile, args: a, env: env)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = cargs
        p.environment = cenv
        let i = Pipe(), o = Pipe()
        p.standardInput = i
        p.standardOutput = o
        do { try p.run() } catch { say("cannot run \(claude): \(error)"); return false }
        child = p
        childIn = i.fileHandleForWriting
        stop.child = p
        return true
    }

    // MARK: extension -> claude

    private func pumpStdin() {
        var pending = Data()
        while case let d = FileHandle.standardInput.availableData, !d.isEmpty {
            pending.append(d)
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...nl)
                remember(line)
                lock.sync { try? childIn?.write(contentsOf: Data((line + "\n").utf8)) }
            }
        }
        lock.sync {
            if !pending.isEmpty { try? childIn?.write(contentsOf: pending) }
            stdinClosed = true
            try? childIn?.close()
        }
    }

    private func remember(_ line: String) {
        guard let obj = FileIO.jsonObject(Data(line.utf8)) else { return }
        switch obj["type"] as? String {
        case "user":
            lock.sync { lastUserLine = line; busy = true }
            if let f = files { FileIO.touch(f.busy) }
        case "control_request":
            guard let id = obj["request_id"] as? String, let sub = (obj["request"] as? [String: Any])?["subtype"] as? String,
                  sub == "initialize" || sub.hasPrefix("set_") else { return }
            lock.sync {
                setup.removeAll { existing in sub != "initialize" && existing.line.contains("\"subtype\":\"\(sub)\"") }
                setup.append((id, line))
            }
        default: break
        }
    }

    // MARK: state

    private func emit(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }

    /// The session record `status`, the app, `switch` and `hold` read.
    private func publish() {
        guard let s = session, let f = files else { return }
        let pid = lock.sync { child?.processIdentifier ?? 0 }
        try? FileIO.encode(SessionRecord(session: s, resume: s, pid: getpid(), child: pid, profile: profile.name,
                                         cwd: FileManager.default.currentDirectoryPath, started: FileIO.isoNow()), to: f.record)
    }

    private func log(type: String, from: String?, to: String?, trigger: String) {
        EventLog.append(HopperEvent(type: type, session: session, cwd: FileManager.default.currentDirectoryPath, from: from, to: to,
                                    trigger: trigger, source: "vscode",
                                    profiles: type == "switch" ? EventLog.samples(HopperConfig.load(env.paths), env.paths, now: FileIO.now()) : nil),
                        env.paths)
    }
}

extension NSLock {
    func sync<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
