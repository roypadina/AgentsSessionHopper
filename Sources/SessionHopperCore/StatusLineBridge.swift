import Foundation

/// `sessionhopper statusline`: Claude Code's status-line command for supervised sessions (and for profiles
/// with `install-hooks`). It records the profile's `rate_limits` from the documented status-line input
/// (https://code.claude.com/docs/en/statusline), then runs the user's own status-line command with the
/// same stdin and prints its output, so their status line keeps working.
public enum StatusLineBridge {
    public static let chainTimeout: TimeInterval = 5

    public static func run(input: Data, env: HopperEnvironment, installedProfile: String?) -> String {
        let profile = env.vars["SESSIONHOPPER_PROFILE"] ?? installedProfile
        let json = FileIO.jsonObject(input) ?? [:]
        let now = FileIO.now()
        let limits = ProfileLimits.fromStatusLine(json, now: now)
        if let profile, let limits { try? LimitStore.write(limits, profile: profile, env.paths) }

        if let command = userCommand(env: env, installedProfile: installedProfile) {
            return Shell.run(command, stdin: input, timeout: chainTimeout).stdout
        }
        // No status line of their own: a short default.
        var parts = [profile ?? "sessionhopper"]
        if let five = limits?.fiveHour { parts.append("5h \(Int(five.usedPercentage.rounded()))%") }
        if let week = limits?.sevenDay { parts.append("7d \(Int(week.usedPercentage.rounded()))%") }
        return parts.joined(separator: " · ") + "\n"
    }

    /// Supervised: the launch passed it in the environment. Installed: the copy saved by `install-hooks`.
    static func userCommand(env: HopperEnvironment, installedProfile: String?) -> String? {
        if let c = env.vars["SESSIONHOPPER_USER_STATUSLINE"], !c.isEmpty { return c }
        guard env.vars["SESSIONHOPPER_PROFILE"] == nil, let p = installedProfile else { return nil }
        return (FileIO.jsonObject(FileIO.read(env.paths.savedStatusLine(p)))?["command"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The `statusLine` the user would get without us: project-local, then project, then the profile's
    /// own settings (Claude Code's precedence, https://code.claude.com/docs/en/settings). If that is ours
    /// (installed by `install-hooks`), the one we replaced.
    // shortcut: looks in `cwd/.claude` only, not in parent directories or managed settings.
    public static func effectiveUserStatusLine(cwd: String, profile: Profile, paths: StatePaths) -> [String: Any]? {
        let candidates = [
            URL(fileURLWithPath: cwd).appendingPathComponent(".claude/settings.local.json"),
            URL(fileURLWithPath: cwd).appendingPathComponent(".claude/settings.json"),
            URL(fileURLWithPath: profile.dir).appendingPathComponent("settings.json")
        ]
        for url in candidates {
            guard let sl = FileIO.jsonObject(FileIO.read(url))?["statusLine"] as? [String: Any] else { continue }
            if isOurs(sl["command"] as? String, kind: "statusline") {
                return FileIO.jsonObject(FileIO.read(paths.savedStatusLine(profile.name)))
            }
            return sl
        }
        return nil
    }

    static func isOurs(_ command: String?, kind: String) -> Bool {
        guard let command else { return false }
        return command.contains("sessionhopper") && command.contains(" \(kind)")
    }
}

/// Runs a /bin/sh command with stdin and a timeout, capturing stdout.
enum Shell {
    struct Result { var status: Int32; var stdout: String }

    static func run(_ command: String, stdin: Data = Data(), timeout: TimeInterval, env: [String: String]? = nil) -> Result {
        run("/bin/sh", ["-c", command], stdin: stdin, timeout: timeout, env: env)
    }

    static func run(_ exe: String, _ args: [String], stdin: Data = Data(), timeout: TimeInterval, env: [String: String]? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let env { p.environment = env }
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return Result(status: 127, stdout: "") }
        let box = OutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            box.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        DispatchQueue.global().async {
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return Result(status: 124, stdout: "")
        }
        p.waitUntilExit()
        return Result(status: p.terminationStatus, stdout: String(data: box.get(), encoding: .utf8) ?? "")
    }

    /// Resolves `name` on PATH (or returns it when it already has a slash).
    static func which(_ name: String, path: String?) -> String? {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in (path ?? "/usr/bin:/bin").split(separator: ":") {
            let full = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }
}

final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
