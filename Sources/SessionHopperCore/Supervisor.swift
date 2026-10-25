import Foundation

public struct LaunchOptions: Sendable {
    /// `-P`: these profiles first, the rest stay as fallbacks.
    public var prefer: [String] = []
    /// `--only`: nothing outside `prefer`.
    public var only = false
    /// `--resume <id>` (adopt) or `--session-id <id>` (new, `sessionIsNew`).
    public var sessionID: String?
    public var sessionIsNew = false
    /// `-c`: the newest resumable session in this directory.
    public var continueLast = false
    /// Everything else goes to `claude` untouched.
    public var claudeArgs: [String] = []
    public init() {}
}

/// Runs the unmodified `claude` for one conversation and moves it to another profile when asked.
///
/// The child stays in our process group, so it keeps the terminal. We ignore SIGINT/SIGQUIT (Ctrl-C
/// belongs to Claude Code) and forward SIGTERM/SIGHUP. A move: SIGTERM the child at a turn end, then
/// `claude --resume <id>` under the next profile's config dir. Moving needs every profile to share one
/// `projects/` directory (`profiles add` links it; `doctor` checks it).
public final class Supervisor {
    enum Outcome { case exited(Int32), handoff(PendingMove) }

    private let env: HopperEnvironment
    private let opts: LaunchOptions
    private let say: (String) -> Void
    private let child = ChildBox()
    private var signalSources: [DispatchSourceSignal] = []
    /// Status-line samples are re-read this often.
    private let evalInterval: TimeInterval

    public init(env: HopperEnvironment, options: LaunchOptions, say: @escaping (String) -> Void) {
        self.env = env
        self.opts = options
        self.say = say
        self.evalInterval = max(env.pollInterval * 4, 0.5)
    }

    public func run() -> Int32 {
        var config = HopperConfig.load(env.paths)
        guard !config.profiles.isEmpty else {
            say("no profiles yet. Run: sessionhopper profiles import   (or: sessionhopper profiles add <name>)")
            return 1
        }
        let fm = FileManager.default
        let projects = Profiles.projectsDir(config, home: env.home)
        let cwd = fm.currentDirectoryPath

        var sessionID = opts.sessionID ?? UUID().uuidString.lowercased()
        var firstRun = opts.sessionID == nil || opts.sessionIsNew
        if opts.continueLast && opts.sessionID == nil {
            let live = Transcripts.liveIDs(config: config, paths: env.paths)
            guard let newest = Transcripts.list(cwd: cwd, projects: projects, live: live, limit: 1).first else {
                say("no resumable session recorded in \(env.tilde(cwd))")
                return 1
            }
            sessionID = newest.id
            firstRun = false
        }
        // `--resume "<name>"`: the name `/resume` shows, as Claude Code itself accepts.
        if UUID(uuidString: sessionID) == nil, !firstRun,
           let id = Transcripts.resolve(name: sessionID, cwd: cwd, projects: projects, live: Transcripts.liveIDs(config: config, paths: env.paths)) {
            sessionID = id
        }
        guard UUID(uuidString: sessionID) != nil else {
            say("'\(sessionID)' is not a session id. List them with: sessionhopper sessions")
            return 1
        }
        if !firstRun {
            if Transcripts.liveIDs(config: config, paths: env.paths).contains(sessionID) {
                say("session \(sessionID) is open in another process. End it there first.")
                return 1
            }
            // A session belongs to the directory it was recorded in; relative paths in it point there.
            if let t = Transcripts.find(sessionID, projects: projects), let dir = Transcripts.cwd(of: t),
               dir != cwd, fm.fileExists(atPath: dir) {
                say("that session belongs to \(env.tilde(dir)), continuing there")
                fm.changeCurrentDirectoryPath(dir)
            }
        }

        let (claudeArgs, callerSettings) = LaunchPlan.extractSettings(opts.claudeArgs)
        installSignalHandlers()
        let files = env.paths.session(sessionID)
        defer { files.all.forEach(FileIO.remove) }
        FileIO.remove(files.hold)
        FileIO.remove(files.current)

        var request: PendingMove?
        var current: Profile?
        var launches = 0
        while true {
            if child.terminating { return 128 + SIGTERM }
            config = HopperConfig.load(env.paths)
            let order = (try? config.order(prefer: opts.prefer, only: opts.only)) ?? config.profiles
            let policy = Policy(config: config, limits: LimitStore.all(config, env.paths), now: FileIO.now())
            let resumeID = FileIO.readString(files.current) ?? sessionID

            if request?.to == PendingMove.park {
                return park(sessionID: resumeID, from: current, request: request, policy: policy, order: order, files: files)
            }
            var target: Profile?
            if let r = request, r.to != PendingMove.anywhere {
                target = config.profile(named: r.to)
            }
            target = target ?? policy.pick(order, excluding: current?.name)
            if target == nil, !config.parkBeforePaid {
                // The user accepts paid usage: keep going on the first profile in order.
                target = order.first { $0.name != current?.name } ?? order.first
            }
            guard let profile = target else {
                return park(sessionID: resumeID, from: current, request: request, policy: policy, order: order, files: files)
            }

            let pct = policy.percent(profile.name).map { "\(Int($0.rounded()))%" } ?? "usage unknown"
            if let from = current, from.name != profile.name {
                say("moving to \(profile.name) (\(pct)), resuming the same conversation")
                EventLog.append(HopperEvent(type: "switch", session: resumeID, cwd: fm.currentDirectoryPath, from: from.name,
                                            to: profile.name, trigger: request?.trigger, source: request?.source,
                                            profiles: EventLog.samples(config, env.paths, now: FileIO.now())), env.paths)
            } else if current == nil {
                let skipped = request == nil ? policy.skipped(order, before: profile) : []
                say("starting on \(profile.name) (\(pct))" + (skipped.isEmpty ? "" : ", skipped " + skipped.joined(separator: ", ")))
            }

            var args: [String]
            let settings = LaunchPlan.settingsJSON(
                selfPath: env.selfPath,
                userStatusLine: StatusLineBridge.effectiveUserStatusLine(cwd: fm.currentDirectoryPath, profile: profile, paths: env.paths),
                caller: callerSettings)
            if firstRun {
                args = ["--session-id", sessionID, "--settings", settings] + claudeArgs
            } else {
                args = ["--resume", resumeID, "--settings", settings]
                args += launches == 0 ? claudeArgs : LaunchPlan.relaunchArgs(claudeArgs)
                let cutOff = FileIO.readString(files.killed)
                // The last turn died on an API error (a limit stop) and the user moved on: pick the work back up.
                let died = FileIO.exists(files.interrupted) || request?.trigger == "limit_stop"
                // The transcript shows a turn that never got its reply, even if the hooks' turn state missed it.
                let unfinished = !Transcripts.turnFinished(Transcripts.find(resumeID, projects: projects))
                if launches > 0, cutOff != nil || died || unfinished {
                    let jobs = (cutOff ?? "").split(separator: "\n").dropFirst().map(String.init)
                    let crons = (FileIO.readString(files.crons) ?? "").split(separator: "\n").map(String.init)
                    args.append(LaunchPlan.continuePrompt(jobs: jobs, crons: crons, limitStop: died, from: current?.name ?? "",
                                                          to: profile.name, template: config.continuePrompt))
                }
            }
            files.turnFiles.forEach(FileIO.remove)

            let userCommand = StatusLineBridge.effectiveUserStatusLine(cwd: fm.currentDirectoryPath, profile: profile, paths: env.paths)?["command"] as? String
            let childEnv = LaunchPlan.childEnvironment(base: env.vars, profile: profile, sessionID: sessionID, env: env, userStatusCommand: userCommand)
            let pid: pid_t
            do {
                pid = try Spawn.run(env.claudeBin, args: args, env: childEnv)
            } catch {
                say("\(error)")
                return 127
            }
            child.set(pid)
            firstRun = false
            launches += 1
            current = profile
            try? FileIO.encode(SessionRecord(session: sessionID, resume: resumeID, pid: getpid(), child: pid, profile: profile.name,
                                             cwd: fm.currentDirectoryPath, started: FileIO.isoNow()), to: files.record)

            switch watch(pid, profile: profile, order: order, files: files, sessionID: resumeID) {
            case .exited(let code):
                child.set(0)
                return code
            case .handoff(let move):
                child.set(0)
                request = move
            }
        }
    }

    // MARK: - Watching one launch

    private func watch(_ pid: pid_t, profile: Profile, order: [Profile], files: SessionFiles, sessionID: String) -> Outcome {
        var lastEval = Date.distantPast
        var limitHit = false
        while true {
            if let code = Spawn.reap(pid, block: false) { return .exited(code) }
            if !child.terminating {
                if let now = FileIO.decode(PendingMove.self, from: files.ctl) {
                    FileIO.remove(files.ctl)
                    if now.to != profile.name { end(pid, files: files); return .handoff(now) }
                }
                if let p = FileIO.decode(PendingMove.self, from: files.pending), idle(files), turnFinished(sessionID) {
                    if p.to == profile.name {
                        FileIO.remove(files.pending)
                    } else {
                        end(pid, files: files)
                        return .handoff(p)
                    }
                }
                if FileIO.exists(files.limited) {
                    limitHit = true
                    onLimit(profile: profile, order: order, files: files, sessionID: sessionID)
                    continue
                }
                if Date().timeIntervalSince(lastEval) >= evalInterval {
                    lastEval = Date()
                    evaluate(profile: profile, order: order, files: files, sessionID: sessionID, limitHit: limitHit)
                }
            }
            Thread.sleep(forTimeInterval: env.pollInterval)
        }
    }

    private func idle(_ f: SessionFiles) -> Bool { !FileIO.exists(f.busy) && !FileIO.hasContent(f.jobs) }

    /// The transcript agrees the turn is over: the busy flag alone once let a move cut a reply off.
    private func turnFinished(_ id: String) -> Bool {
        Transcripts.turnFinished(Transcripts.find(id, projects: Profiles.projectsDir(HopperConfig.load(env.paths), home: env.home)))
    }

    private func held(_ f: SessionFiles) -> Bool { FileIO.exists(env.paths.holdAll) || FileIO.exists(f.hold) }

    private func evaluate(profile: Profile, order: [Profile], files f: SessionFiles, sessionID: String, limitHit: Bool) {
        let config = HopperConfig.load(env.paths)
        let policy = Policy(config: config, limits: LimitStore.all(config, env.paths), now: FileIO.now())
        let pendingExists = FileIO.exists(f.pending)
        let decision = policy.evaluate(current: profile, order: order, held: held(f))
        if policy.isUrgent(decision, current: profile), !FileIO.exists(f.ctl) {
            switch decision {
            case .autoMove(let to, _):
                try? FileIO.encode(PendingMove(to: to, trigger: "hard", source: "engine"), to: f.ctl)
                return
            case .park where !limitHit:
                try? FileIO.encode(PendingMove(to: PendingMove.park, trigger: "park", source: "engine"), to: f.ctl)
                return
            default: break
            }
        }
        switch decision {
        case .none:
            break
        case .suggest(let to, let pct):
            guard !pendingExists, !FileIO.exists(f.suggest) else { return }
            try? FileIO.encode(Suggestion(from: profile.name, to: to, percent: pct, reason: "threshold"), to: f.suggest)
            EventLog.append(HopperEvent(type: "suggest", session: sessionID, cwd: FileManager.default.currentDirectoryPath,
                                        from: profile.name, to: to, trigger: "threshold", source: "engine",
                                        profiles: EventLog.samples(config, env.paths, now: policy.now)), env.paths)
        case .autoMove(let to, _):
            guard !pendingExists else { return }
            try? FileIO.encode(PendingMove(to: to, trigger: "auto", source: "engine"), to: f.pending)
            FileIO.remove(f.suggest)
        case .park:
            // Not after a limit stop: nothing is billed while Claude Code is stopped, so ask instead.
            guard !pendingExists, !limitHit else { return }
            try? FileIO.encode(PendingMove(to: PendingMove.park, trigger: "park", source: "engine"), to: f.pending)
        }
    }

    /// StopFailure with `rate_limit`: the turn already ended. Move if the user confirmed or opted in, else ask.
    private func onLimit(profile: Profile, order: [Profile], files f: SessionFiles, sessionID: String) {
        let detail = FileIO.readString(f.limited)
        FileIO.remove(f.limited)
        let config = HopperConfig.load(env.paths)
        let policy = Policy(config: config, limits: LimitStore.all(config, env.paths), now: FileIO.now())
        let samples = EventLog.samples(config, env.paths, now: policy.now)
        let cwd = FileManager.default.currentDirectoryPath
        EventLog.append(HopperEvent(type: "limit", session: sessionID, cwd: cwd, from: profile.name, trigger: "limit",
                                    source: "hook", detail: detail, profiles: samples), env.paths)
        if var p = FileIO.decode(PendingMove.self, from: f.pending), p.to != PendingMove.park {
            p.trigger = "limit_stop"
            try? FileIO.encode(p, to: f.pending)
            return
        }
        let to = policy.pick(order, excluding: profile.name)
        if config.autoMove, !held(f), let to {
            try? FileIO.encode(PendingMove(to: to.name, trigger: "limit_stop", source: "engine"), to: f.pending)
        } else {
            FileIO.remove(f.pending)
            FileIO.remove(f.suggestShown)
            try? FileIO.encode(Suggestion(from: profile.name, to: to?.name, percent: policy.percent(profile.name), reason: "limit"), to: f.suggest)
            EventLog.append(HopperEvent(type: "suggest", session: sessionID, cwd: cwd, from: profile.name, to: to?.name,
                                        trigger: "limit", source: "engine", profiles: samples), env.paths)
        }
    }

    /// End the child at a clean point (or now). Records what was cut off for the relaunch prompt.
    private func end(_ pid: pid_t, files f: SessionFiles) {
        if !idle(f) {
            try? FileIO.write("interrupted\n" + (FileIO.readString(f.jobs) ?? ""), to: f.killed)
        }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(env.killGrace)
        while Date() < deadline {
            if Spawn.reap(pid, block: false) != nil { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(pid, SIGKILL)
        _ = Spawn.reap(pid, block: true)
    }

    private func park(sessionID: String, from: Profile?, request: PendingMove?, policy: Policy, order: [Profile], files: SessionFiles) -> Int32 {
        let config = policy.config
        EventLog.append(HopperEvent(type: "park", session: sessionID, cwd: FileManager.default.currentDirectoryPath,
                                    from: from?.name, trigger: request?.trigger ?? "launch", source: request?.source ?? "engine",
                                    profiles: EventLog.samples(config, env.paths, now: policy.now)), env.paths)
        if let from, request?.trigger == "park" {
            say("parked: \(from.name) reached \(Int(config.hardThreshold))% and \"park before paid usage\" is on")
        } else if from != nil {
            say("parked: no other profile has room")
        } else {
            say("no profile with room (all at \(Int(config.hardThreshold))%+ of a window); not starting, so nothing runs into paid usage")
        }
        for p in order {
            let w = policy.limits[p.name]?.blocking(now: policy.now)
            let usage = w.map { "\($0.name) \(Int($0.window.usedPercentage.rounded()))%" } ?? "unknown"
            let reset = w?.window.resetsAt.map { "resets \(Self.clock($0))" } ?? ""
            say("  \(p.name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(usage)  \(reset)")
        }
        say("session kept. Continue later:  sessionhopper --resume \(sessionID)")
        say("or on a chosen profile now:     sessionhopper -P <profile> --resume \(sessionID)")
        return 2
    }

    static func clock(_ epoch: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(Date(timeIntervalSince1970: epoch)) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: Date(timeIntervalSince1970: epoch))
    }

    private func installSignalHandlers() {
        // Ctrl-C and Ctrl-\ belong to Claude Code, which gets them from the terminal directly.
        signal(SIGINT, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)
        for sig in [SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            let box = child
            src.setEventHandler { box.terminate(sig) }
            src.resume()
            signalSources.append(src)
        }
    }
}

final class ChildBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var _terminating = false

    func set(_ p: pid_t) { lock.lock(); pid = p; lock.unlock() }

    var terminating: Bool { lock.lock(); defer { lock.unlock() }; return _terminating }

    func terminate(_ sig: Int32) {
        lock.lock()
        _terminating = true
        let p = pid
        lock.unlock()
        if p > 0 { kill(p, sig) }
    }
}

enum Spawn {
    /// posix_spawnp with default dispositions for the signals we ignore, so the child behaves as if the
    /// shell had started it. Same process group: the child keeps the terminal.
    static func run(_ exe: String, args: [String], env: [String: String]) throws -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaults: sigset_t = 0
        for s in [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE] { defaults |= sigset_t(1) << sigset_t(s - 1) }
        var empty: sigset_t = 0
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &empty)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawnp(&pid, exe, nil, &attr, argv, envp)
        guard rc == 0 else { throw HopperError("cannot start \(exe): \(String(cString: strerror(rc)))") }
        return pid
    }

    /// Exit code (128 + signal when killed), or nil while it runs.
    static func reap(_ pid: pid_t, block: Bool) -> Int32? {
        var status: Int32 = 0
        let r = waitpid(pid, &status, block ? 0 : WNOHANG)
        if r == 0 { return nil }
        if r < 0 { return errno == EINTR ? nil : 1 }
        let sig = status & 0x7f
        return sig == 0 ? (status >> 8) & 0xff : 128 + sig
    }
}
