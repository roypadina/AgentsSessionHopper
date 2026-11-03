import Foundation

/// `sessionhopper run -- <claude args>`: one non-interactive `claude -p` run for callers such as a bot or a
/// systemd service. Picks the profile, runs the unmodified `claude`, and when the run fails on a limit
/// retries the same turn on the next profile.
///
/// Usage comes from Claude Code's own output: with `--output-format stream-json` every run prints a
/// `rate_limit_event` with the 5-hour and 7-day utilization and reset times. No network, no token read.
public enum OneShot {
    public enum Format: String, Sendable { case text, json, streamJSON = "stream-json" }

    /// Exit code when no profile can take the run (EX_TEMPFAIL).
    public static let allFullExit: Int32 = 75

    /// The caller's args with `--output-format stream-json --verbose` (and `-p`) in place of their own
    /// format, which `run` renders back.
    public static func prepare(_ args: [String]) -> (args: [String], format: Format) {
        var out: [String] = []
        var format = Format.text
        var i = 0
        while i < args.count {
            if args[i] == "--output-format", i + 1 < args.count {
                format = Format(rawValue: args[i + 1]) ?? .text
                i += 2
                continue
            }
            if args[i].hasPrefix("--output-format=") {
                format = Format(rawValue: String(args[i].dropFirst(16))) ?? .text
            } else {
                out.append(args[i])
            }
            i += 1
        }
        if !out.contains("-p"), !out.contains("--print") { out.insert("-p", at: 0) }
        out += ["--output-format", "stream-json"]
        if !out.contains("--verbose") { out.append("--verbose") }
        return (out, format)
    }

    /// The conversation id the caller named with `--session-id` or `--resume`.
    public static func sessionID(_ args: [String]) -> String? {
        for flag in ["--session-id", "--resume", "-r"] {
            if let i = args.firstIndex(of: flag), i + 1 < args.count { return args[i + 1] }
            if let v = args.first(where: { $0.hasPrefix(flag + "=") }) { return String(v.dropFirst(flag.count + 1)) }
        }
        return nil
    }

    /// On a retry, `--session-id X` becomes `--resume X` once the failed attempt wrote X's transcript
    /// (Claude Code refuses a `--session-id` that already exists).
    public static func retryArgs(_ args: [String], projects: URL) -> [String] {
        var out = args
        if let i = args.firstIndex(where: { $0.hasPrefix("--session-id=") }) {
            out[i...i] = ["--session-id", String(args[i].dropFirst("--session-id=".count))]
        }
        guard let i = out.firstIndex(of: "--session-id"), i + 1 < out.count,
              Transcripts.find(out[i + 1], projects: projects) != nil else { return args }
        out[i] = "--resume"
        return out
    }

    /// What one attempt printed.
    public struct Attempt: Sendable {
        public var limits: ProfileLimits?
        /// `rate_limit_event` with status "rejected": which window, and when it resets.
        public var rejected: (type: String, resetsAt: Double?)?
        public var resultLine: String?
        public var resultText: String?
        public var isError = false
        public var stderr = ""
        public var exit: Int32 = 0
        public init() {}

        /// Feeds one stdout line.
        public mutating func read(line: String, now: Double) {
            guard let obj = FileIO.jsonObject(Data(line.utf8)) else { return }
            switch obj["type"] as? String {
            case "rate_limit_event":
                guard let info = obj["rate_limit_info"] as? [String: Any] else { return }
                if let l = OneShot.limits(info, now: now) { limits = l }
                if info["status"] as? String == "rejected" {
                    rejected = (info["rateLimitType"] as? String ?? "five_hour", (info["resetsAt"] as? NSNumber)?.doubleValue)
                }
            case "result":
                resultLine = line
                resultText = obj["result"] as? String
                isError = obj["is_error"] as? Bool ?? (obj["subtype"] as? String != "success")
            default: break
            }
        }
    }

    /// `rate_limit_info.unifiedWindows` (utilization is a fraction) → the same numbers the status line gives.
    public static func limits(_ info: [String: Any], now: Double) -> ProfileLimits? {
        guard let w = info["unifiedWindows"] as? [String: Any] else { return nil }
        func window(_ key: String) -> LimitWindow? {
            guard let o = w[key] as? [String: Any], let u = (o["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return LimitWindow(usedPercentage: u * 100, resetsAt: (o["resetsAt"] as? NSNumber)?.doubleValue)
        }
        let five = window("five_hour"), week = window("seven_day")
        guard five != nil || week != nil else { return nil }
        return ProfileLimits(fiveHour: five, sevenDay: week, sampledAt: now)
    }

    public enum Failure: Equatable, Sendable {
        case none
        /// Out of quota until then (nil: unknown).
        case limit(until: Double?, weekly: Bool)
        /// Pay-per-use key out of credit (HTTP 402).
        case credits
        /// The login or key does not work.
        case login
        /// Failed for another reason: not retried.
        case other
    }

    static let limitPhrases = ["usage limit", "session limit", "weekly limit", "rate limit", "limit reached", "hit your limit"]
    static let creditPhrases = ["402", "requires more credits", "insufficient credits"]
    static let loginPhrases = ["not logged in", "please run /login", "oauth access token is invalid", "failed to authenticate", "authentication_error",
                               "invalid bearer token", "invalid api key", "401"]

    public static func classify(_ a: Attempt, now: Double) -> Failure {
        if let r = a.rejected { return .limit(until: r.resetsAt, weekly: r.type.contains("seven")) }
        guard a.isError || a.exit != 0 || a.resultLine == nil else { return .none }
        let blob = ((a.resultText ?? "") + "\n" + a.stderr).lowercased()
        if creditPhrases.contains(where: blob.contains) { return .credits }
        if limitPhrases.contains(where: blob.contains) {
            return .limit(until: resetEpoch(blob, now: now), weekly: blob.contains("weekly") || blob.contains("7-day"))
        }
        if loginPhrases.contains(where: blob.contains) { return .login }
        return .other
    }

    /// Reset time in Claude Code's limit text: "limit reached|<epoch>", or "resets Nov 3, 8pm (UTC)" /
    /// "resets 3:30am (UTC)". Only UTC times are read; anything else gives nil.
    public static func resetEpoch(_ text: String, now: Double) -> Double? {
        let t = text.lowercased()
        if let r = t.range(of: #"limit reached\|(\d{9,13})"#, options: .regularExpression) {
            let digits = t[r].split(separator: "|").last.flatMap { Double($0) } ?? 0
            return digits > 1e11 ? digits / 1000 : digits
        }
        guard let r = t.range(of: #"resets (?:([a-z]{3}) (\d{1,2}), )?(\d{1,2})(?::(\d{2}))?\s*([ap]m) \(utc\)"#, options: .regularExpression) else { return nil }
        let words = t[r].dropFirst("resets ".count).replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "(utc)", with: "")
            .split(separator: " ").map(String.init)
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let today = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: now))
        var c = DateComponents(timeZone: cal.timeZone, year: today.year, month: today.month, day: today.day)
        var clock = words.last ?? ""
        if words.count >= 3, let m = months.firstIndex(of: words[0]), let d = Int(words[1]) {
            c.month = m + 1
            c.day = d
            clock = words[2...].joined()
        }
        let pm = clock.hasSuffix("pm")
        let hm = clock.dropLast(2).split(separator: ":")
        guard let h = hm.first.flatMap({ Int($0) }) else { return nil }
        c.hour = h % 12 + (pm ? 12 : 0)
        c.minute = hm.count > 1 ? Int(hm[1]) ?? 0 : 0
        guard var at = cal.date(from: c)?.timeIntervalSince1970 else { return nil }
        if words.count >= 3, months.contains(words[0]) {
            if at < now - 86_400 { at = cal.date(byAdding: .year, value: 1, to: Date(timeIntervalSince1970: at))?.timeIntervalSince1970 ?? at }
        } else if at <= now {
            at += 86_400
        }
        return at
    }

    /// Records what a failed attempt says about its profile, so the next pick passes it over until the reset.
    static func markFull(_ p: Profile, _ f: Failure, attempt: Attempt, paths: StatePaths, now: Double) {
        switch f {
        case .credits:
            Gateway.markFull(p, until: Gateway.nextReset(p, now: now), paths: paths, now: now)
        case .limit(let until, let weekly):
            var l = attempt.limits ?? LimitStore.read(p.name, paths) ?? ProfileLimits(fiveHour: nil, sevenDay: nil, sampledAt: now)
            // shortcut: no reset in the output → assume one hour, as the next run's sample corrects it.
            let full = LimitWindow(usedPercentage: 100, resetsAt: until ?? now + 3600)
            if p.isGateway { l.spendLimit = full } else if weekly { l.sevenDay = full } else { l.fiveHour = full }
            l.sampledAt = now
            try? LimitStore.write(l, profile: p.name, paths)
        default: break
        }
    }

    /// Runs the turn. `stdin` is the whole prompt input, replayed on each attempt.
    public static func run(env: HopperEnvironment, prefer: [String], only: Bool, args callerArgs: [String], stdin: Data,
                           say: (String) -> Void) -> Int32 {
        let config = HopperConfig.load(env.paths)
        guard !config.profiles.isEmpty else { say("no profiles yet. Run: sessionhopper profiles import"); return 1 }
        guard let claude = Claude.locate(env) else { say("claude not found on PATH"); return 127 }
        let order: [Profile]
        do { order = try config.order(prefer: prefer, only: only) } catch { say("\(error)"); return 2 }
        let projects = Profiles.projectsDir(config, home: env.home)
        var (args, format) = prepare(callerArgs)
        let session = sessionID(callerArgs)
        let stop = Terminator()
        var skipped: Set<String> = []
        var last: Attempt?
        var lastProfile: Profile?

        while !stop.requested {
            let now = FileIO.now()
            let policy = Policy(config: config, limits: LimitStore.all(config, env.paths), now: now)
            guard let p = policy.pick(order.filter { !skipped.contains($0.name) }) else { break }
            if p.isGateway, Claude.isLoggedIn(p, env: env) != true {
                say("\(p.name): no API key (\(Gateway.keySource(p, env: env))), skipping it")
                skipped.insert(p.name)
                continue
            }
            if let from = lastProfile {
                say("\(from.name) cannot take this run, retrying on \(p.name)")
                args = retryArgs(args, projects: projects)
            }
            let childEnv = LaunchPlan.childEnvironment(base: env.vars, profile: p, sessionID: "", env: env, userStatusCommand: nil)
            var a = attempt(claude, args: p.isGateway ? Gateway.modelArgs(args, p) : args, env: childEnv, stdin: stdin,
                            passThrough: format == .streamJSON, stop: stop)
            if let l = a.limits, !p.isGateway { try? LimitStore.write(l, profile: p.name, env.paths) }
            let failure = classify(a, now: FileIO.now())
            switch failure {
            case .none, .other:
                EventLog.append(HopperEvent(type: "run", session: session, cwd: FileManager.default.currentDirectoryPath, from: lastProfile?.name,
                                            to: p.name, trigger: failure == .none ? "ok" : "error", source: "run",
                                            detail: failure == .none ? nil : (a.resultText ?? a.stderr).prefix(200).description), env.paths)
                emit(a, format)
                return a.exit
            case .limit, .credits, .login:
                markFull(p, failure, attempt: a, paths: env.paths, now: FileIO.now())
                let why = failure == .login ? "login" : failure == .credits ? "credits" : "limit"
                EventLog.append(HopperEvent(type: "limit", session: session, cwd: FileManager.default.currentDirectoryPath, from: p.name,
                                            trigger: why, source: "run", detail: (a.resultText ?? a.stderr).prefix(200).description,
                                            profiles: EventLog.samples(config, env.paths, now: FileIO.now())), env.paths)
                skipped.insert(p.name)
                a.stderr = ""
                last = a
                lastProfile = p
            }
        }
        if stop.requested { return 128 + SIGTERM }
        let policy = Policy(config: config, limits: LimitStore.all(config, env.paths), now: FileIO.now())
        let next = policy.nextRoom(order).map { " First reset: \($0.profile.name) at \(ProfileLimits.clock($0.at))." } ?? ""
        say("no profile can take this run." + next)
        for p in order { say("  \(p.name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(skipped.contains(p.name) && LimitStore.read(p.name, env.paths) == nil ? "unusable" : ProfileLimits.label(policy.limits[p.name], now: policy.now))") }
        if let last { emit(last, format) }
        return allFullExit
    }

    /// The caller's format: text = the result text, json = the result object. stream-json went out live.
    static func emit(_ a: Attempt, _ format: Format) {
        switch format {
        case .text: if let t = a.resultText { FileHandle.standardOutput.write(Data((t + "\n").utf8)) }
        case .json: if let l = a.resultLine { FileHandle.standardOutput.write(Data((l + "\n").utf8)) }
        case .streamJSON: break
        }
    }

    /// One `claude` run: stdin in, stdout parsed line by line, stderr shown and kept for classification.
    static func attempt(_ claude: String, args: [String], env: [String: String], stdin: Data, passThrough: Bool, stop: Terminator) -> Attempt {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claude)
        proc.arguments = args
        proc.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        var a = Attempt()
        do { try proc.run() } catch {
            a.exit = 127
            a.stderr = "cannot run \(claude): \(error)"
            return a
        }
        stop.child = proc
        let group = DispatchGroup()
        let errBox = LockedData()
        DispatchQueue.global().async(group: group) {
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        DispatchQueue.global().async(group: group) {
            while case let d = errPipe.fileHandleForReading.availableData, !d.isEmpty {
                FileHandle.standardError.write(d)
                errBox.append(d, cap: 64 * 1024)
            }
        }
        var pending = Data()
        while case let d = outPipe.fileHandleForReading.availableData, !d.isEmpty {
            if passThrough { FileHandle.standardOutput.write(d) }
            pending.append(d)
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...nl)
                a.read(line: line, now: FileIO.now())
            }
        }
        if !pending.isEmpty { a.read(line: String(decoding: pending, as: UTF8.self), now: FileIO.now()) }
        proc.waitUntilExit()
        group.wait()
        stop.child = nil
        a.exit = proc.terminationReason == .uncaughtSignal ? 128 + proc.terminationStatus : proc.terminationStatus
        a.stderr = String(decoding: errBox.data, as: UTF8.self)
        return a
    }
}

/// SIGTERM / SIGINT / SIGHUP (systemd stop, Ctrl-C) end the running `claude` and stop retrying.
final class Terminator: @unchecked Sendable {
    private let lock = NSLock()
    private var _child: Process?
    private var _requested = false
    private var sources: [DispatchSourceSignal] = []

    init() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            s.setEventHandler { [weak self] in self?.fire(sig) }
            s.resume()
            sources.append(s)
        }
    }

    var child: Process? {
        get { lock.lock(); defer { lock.unlock() }; return _child }
        set { lock.lock(); _child = newValue; lock.unlock() }
    }

    var requested: Bool { lock.lock(); defer { lock.unlock() }; return _requested }

    private func fire(_ sig: Int32) {
        lock.lock()
        _requested = true
        let c = _child
        lock.unlock()
        if let c, c.isRunning { kill(c.processIdentifier, sig) }
    }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var buf = Data()
    func append(_ d: Data, cap: Int) { lock.lock(); if buf.count < cap { buf.append(d.prefix(cap - buf.count)) }; lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buf }
}
