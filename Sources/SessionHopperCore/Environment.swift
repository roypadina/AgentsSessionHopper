import Foundation

/// Where everything lives, resolved once per process. Every path can be overridden through
/// `SESSIONHOPPER_*` variables, which is how the tests run against temp dirs and a fake `claude`.
public struct HopperEnvironment: Sendable {
    /// The user's home: profile discovery looks for `~/.claude` and `~/.claude-*` here.
    public var home: URL
    public var paths: StatePaths
    /// `claude` (looked up on PATH) or an absolute path.
    public var claudeBin: String
    /// Absolute path of the `sessionhopper` binary, used in the hook and status-line commands.
    public var selfPath: String
    /// Seconds Claude Code gets to exit after SIGTERM before SIGKILL.
    public var killGrace: TimeInterval
    /// Supervisor tick. Control files and the turn state are checked once per tick.
    public var pollInterval: TimeInterval
    /// The process environment the supervisor starts from.
    public var vars: [String: String]

    public init(home: URL, stateDir: URL, claudeBin: String = "claude", selfPath: String,
                killGrace: TimeInterval = 10, pollInterval: TimeInterval = 0.25, vars: [String: String] = [:]) {
        self.home = home
        self.paths = StatePaths(root: stateDir)
        self.claudeBin = claudeBin
        self.selfPath = selfPath
        self.killGrace = killGrace
        self.pollInterval = pollInterval
        self.vars = vars
    }

    public static func current(selfPath: String? = nil) -> HopperEnvironment {
        let vars = ProcessInfo.processInfo.environment
        let home = vars["SESSIONHOPPER_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let state = vars["SESSIONHOPPER_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? defaultStateDir()
        return HopperEnvironment(
            home: home,
            stateDir: state,
            claudeBin: vars["SESSIONHOPPER_CLAUDE_BIN"] ?? "claude",
            selfPath: selfPath ?? Bundle.main.executablePath ?? CommandLine.arguments[0],
            killGrace: vars["SESSIONHOPPER_KILL_GRACE"].flatMap(TimeInterval.init) ?? 10,
            pollInterval: vars["SESSIONHOPPER_POLL"].flatMap(TimeInterval.init) ?? 0.25,
            vars: vars)
    }

    public static func defaultStateDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentsSessionHopper", isDirectory: true)
    }

    /// The session this process runs inside, when started by `sessionhopper`.
    public var currentSessionID: String? { vars["SESSIONHOPPER_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 } }

    /// `~/x` for display.
    public func tilde(_ path: String) -> String {
        let h = home.path
        if path == h { return "~" }
        return path.hasPrefix(h + "/") ? "~" + path.dropFirst(h.count) : path
    }
}

/// The state directory: one file protocol shared by the CLI, the hooks and the app.
public struct StatePaths: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public var config: URL { root.appendingPathComponent("config.json") }
    /// The switch log, one JSON object per line.
    public var events: URL { root.appendingPathComponent("events.jsonl") }
    public var holdAll: URL { root.appendingPathComponent("hold-all") }
    public var sessionsDir: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    public var profilesDir: URL { root.appendingPathComponent("profiles", isDirectory: true) }
    public var backupsDir: URL { root.appendingPathComponent("backups", isDirectory: true) }

    public func limits(_ profile: String) -> URL { profilesDir.appendingPathComponent("\(profile).limits.json") }
    /// The user's own status line, kept when `install-hooks` put ours in its place.
    public func savedStatusLine(_ profile: String) -> URL { profilesDir.appendingPathComponent("\(profile).statusline.json") }
    public func session(_ id: String) -> SessionFiles { SessionFiles(dir: sessionsDir, id: id) }
}

/// Per-session files. Small, single-purpose, written by temp file + rename.
public struct SessionFiles: Sendable {
    public let dir: URL
    public let id: String
    private func f(_ ext: String) -> URL { dir.appendingPathComponent("\(id).\(ext)") }

    /// Live session record (`SessionRecord`), removed when the supervisor exits.
    public var record: URL { f("json") }
    /// A turn is running (UserPromptSubmit sets it, Stop / StopFailure clear it).
    public var busy: URL { f("busy") }
    /// Background tasks still running at the last Stop, one per line.
    public var jobs: URL { f("jobs") }
    /// A confirmed hand-off (`PendingMove`), carried out when the session is idle.
    public var pending: URL { f("pending") }
    /// "Move now", even mid-turn.
    public var ctl: URL { f("ctl") }
    /// A suggestion waiting for the user (`Suggestion`).
    public var suggest: URL { f("suggest") }
    public var suggestShown: URL { f("suggest-shown") }
    /// The agent was told about the pending move.
    public var warned: URL { f("warned") }
    public var hold: URL { f("hold") }
    /// What was cut off when a move ended a turn early.
    public var killed: URL { f("killed") }
    /// The last turn died on an API error (StopFailure).
    public var interrupted: URL { f("interrupted") }
    /// The last turn died on `rate_limit`.
    public var limited: URL { f("limited") }
    /// The last turn died because this profile cannot run (login expired, org not allowed, account on hold).
    public var loginFailed: URL { f("login-failed") }
    /// Conversation id after `/clear` (Claude Code starts a new one in the same process).
    public var current: URL { f("current") }
    /// Scheduled tasks (`Stop.session_crons`) at the last Stop, one per line.
    public var crons: URL { f("crons") }

    /// Turn state cleared on every (re)launch.
    public var turnFiles: [URL] { [busy, jobs, pending, ctl, suggest, suggestShown, warned, killed, interrupted, limited, loginFailed, crons] }
    public var all: [URL] { turnFiles + [record, hold, current] }
}
