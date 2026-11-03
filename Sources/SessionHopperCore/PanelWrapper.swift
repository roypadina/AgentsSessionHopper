import Foundation

/// The Claude Code VS Code extension's `claudeCode.claudeProcessWrapper`: set it to `sessionhopper` and the
/// extension runs `sessionhopper <its bundled claude> <flags>` for every panel conversation (and `auth status`).
///
/// Each start or resume is placed on a profile by the same rules as everywhere else (first Claude profile with
/// room, OpenRouter last). The extension's stream-json traffic is passed through byte for byte; the wrapper only
/// reads `rate_limit_event` lines (usage for `status` and the app) and turn results. When a turn fails on a usage
/// limit, the profile is marked full and that `claude` ends, so reopening the conversation (or Retry) resumes it on
/// the next profile. Nothing is replayed or injected.
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

    /// The profile for this start: by policy; with every profile full, the first in order (claude then shows
    /// its own usage-limit message in the panel).
    public static func pick(_ config: HopperConfig, env: HopperEnvironment, now: Double) -> Profile? {
        let usable = config.profiles.filter { !$0.isGateway || Claude.isLoggedIn($0, env: env) == true }
        let policy = Policy(config: config, limits: LimitStore.all(config, env.paths), now: now)
        return policy.pick(usable) ?? usable.first { !$0.isGateway }
    }

    public static func run(env: HopperEnvironment, args: [String], say: (String) -> Void) -> Int32 {
        let claude = args[0]
        let rest = Array(args.dropFirst())
        let config = HopperConfig.load(env.paths)
        guard let p = pick(config, env: env, now: FileIO.now()) else { return exec(claude, rest, env.vars) }
        let (cargs, cenv) = launch(p, args: rest, env: env)
        // Non-conversation calls (`auth status --json`, MCP helpers): run on the chosen profile, untouched.
        guard rest.contains("--input-format"), rest.contains("stream-json") else { return exec(claude, cargs, cenv) }

        let session = OneShot.sessionID(rest)
        EventLog.append(HopperEvent(type: "run", session: session, cwd: FileManager.default.currentDirectoryPath, to: p.name,
                                    trigger: session == nil ? "start" : "resume", source: "vscode"), env.paths)
        return proxy(claude, args: cargs, env: cenv, profile: p, hopper: env, say: say)
    }

    static func exec(_ claude: String, _ args: [String], _ env: [String: String]) -> Int32 {
        let argv: [UnsafeMutablePointer<CChar>?] = ([claude] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        execve(claude, argv, envp)
        return 127
    }

    static func proxy(_ claude: String, args: [String], env: [String: String], profile p: Profile, hopper: HopperEnvironment,
                      say: (String) -> Void) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claude)
        proc.arguments = args
        proc.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        do { try proc.run() } catch { say("cannot run \(claude): \(error)"); return 127 }
        let stop = Terminator()
        stop.child = proc
        // Extension -> claude, raw. Our stdin closing (panel closed) closes claude's.
        Thread.detachNewThread {
            while case let d = FileHandle.standardInput.availableData, !d.isEmpty { try? inPipe.fileHandleForWriting.write(contentsOf: d) }
            try? inPipe.fileHandleForWriting.close()
        }
        var turn = OneShot.Attempt()
        var pending = Data()
        var session: String?
        var ended = false
        while case let d = outPipe.fileHandleForReading.availableData, !d.isEmpty {
            FileHandle.standardOutput.write(d)
            pending.append(d)
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...nl)
                if session == nil, line.contains("\"session_id\""), let obj = FileIO.jsonObject(Data(line.utf8)) { session = obj["session_id"] as? String }
                guard line.contains("\"rate_limit_event\"") || line.contains("\"type\":\"result\"") else { continue }
                turn.read(line: line, now: FileIO.now())
                if line.contains("\"rate_limit_event\""), let l = turn.limits, !p.isGateway { try? LimitStore.write(l, profile: p.name, hopper.paths) }
                guard turn.resultLine != nil else { continue }
                let failure = OneShot.classify(turn, now: FileIO.now())
                if case .limit = failure { ended = endOnLimit(failure, turn, p, session, hopper, proc, say) }
                if failure == .credits { ended = endOnLimit(failure, turn, p, session, hopper, proc, say) }
                turn = OneShot.Attempt()
            }
        }
        proc.waitUntilExit()
        stop.child = nil
        // Ended for a move: an error exit, so the extension offers to reopen rather than treating it as a clean end.
        if ended { return 75 }
        return proc.terminationReason == .uncaughtSignal ? 128 + proc.terminationStatus : proc.terminationStatus
    }

    /// A turn failed on this profile's usage: mark it, and end this `claude` so the conversation reopens elsewhere.
    @discardableResult
    static func endOnLimit(_ f: OneShot.Failure, _ a: OneShot.Attempt, _ p: Profile, _ session: String?, _ env: HopperEnvironment,
                           _ proc: Process, _ say: (String) -> Void) -> Bool {
        OneShot.markFull(p, f, attempt: a, paths: env.paths, now: FileIO.now())
        let config = HopperConfig.load(env.paths)
        let next = Policy(config: config, limits: LimitStore.all(config, env.paths), now: FileIO.now()).pick(config.profiles)
        EventLog.append(HopperEvent(type: "limit", session: session, cwd: FileManager.default.currentDirectoryPath, from: p.name,
                                    to: next?.name, trigger: f == .credits ? "credits" : "limit", source: "vscode",
                                    detail: (a.resultText ?? "").prefix(200).description,
                                    profiles: EventLog.samples(config, env.paths, now: FileIO.now())), env.paths)
        say(next.map { "\(p.name) is out of usage: reopen this conversation to continue on \($0.name)" } ?? "\(p.name) is out of usage and no profile has room")
        guard next != nil, proc.isRunning else { return false }
        kill(proc.processIdentifier, SIGTERM)
        return true
    }
}
