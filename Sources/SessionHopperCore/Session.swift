import Foundation

/// A live supervised session, as the supervisor publishes it in `sessions/<id>.json`.
public struct SessionRecord: Codable, Equatable, Sendable {
    /// The id the session was started or adopted with; keys every file of this session.
    public var session: String
    /// The id `--resume` uses (differs from `session` after `/clear`).
    public var resume: String
    public var pid: Int32
    public var child: Int32
    public var profile: String
    public var cwd: String
    public var started: String
}

/// A move the user confirmed (or opt-in auto-move queued), done when the session is idle.
public struct PendingMove: Codable, Equatable, Sendable {
    /// Profile name, "-" for "the next one with room", or "park".
    public var to: String
    /// confirm | auto | limit_stop | park | now
    public var trigger: String
    /// menu | notification | cli | engine
    public var source: String

    public init(to: String, trigger: String, source: String) {
        self.to = to
        self.trigger = trigger
        self.source = source
    }

    public static let park = "park"
    public static let anywhere = "-"
}

/// A hand-off the engine proposes; nothing happens until the user confirms.
public struct Suggestion: Codable, Equatable, Sendable {
    public var from: String
    public var to: String?
    public var percent: Double?
    /// threshold | limit
    public var reason: String
    public var dismissed: Bool = false
}

public struct LiveSession: Codable, Equatable, Sendable, Identifiable {
    public var record: SessionRecord
    public var busy: Bool
    public var held: Bool
    public var pending: PendingMove?
    public var suggestion: Suggestion?
    public var id: String { record.session }
}

public enum Sessions {
    /// Supervised sessions whose supervisor is still alive. Stale records (crashed supervisor) are skipped.
    public static func live(_ paths: StatePaths) -> [LiveSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.sessionsDir, includingPropertiesForKeys: nil)) ?? []
        let holdAll = FileIO.exists(paths.holdAll)
        return files.filter { $0.pathExtension == "json" }
            .compactMap { FileIO.decode(SessionRecord.self, from: $0) }
            .filter { FileIO.isAlive($0.pid) }
            .sorted { $0.started < $1.started }
            .map { r in
                let f = paths.session(r.session)
                return LiveSession(record: r, busy: FileIO.exists(f.busy), held: holdAll || FileIO.exists(f.hold),
                                   pending: FileIO.decode(PendingMove.self, from: f.pending),
                                   suggestion: FileIO.decode(Suggestion.self, from: f.suggest))
            }
    }

    public static func find(_ id: String, _ paths: StatePaths) -> LiveSession? {
        live(paths).first { $0.record.session == id || $0.record.resume == id || $0.record.session.hasPrefix(id) }
    }
}

/// Requests from outside the supervisor: the CLI, the app, or the agent itself.
public enum Control {
    /// Confirm a move. `to` nil = the next profile with room. `now` ends the current turn immediately.
    public static func requestMove(session id: String, to: String?, now: Bool, source: String,
                                   env: HopperEnvironment) throws -> LiveSession {
        guard let s = Sessions.find(id, env.paths) else { throw HopperError("no live session \(id) (see: sessionhopper status)") }
        let config = HopperConfig.load(env.paths)
        if let to {
            guard config.profile(named: to) != nil else { throw HopperError("unknown profile '\(to)'") }
            guard to != s.record.profile else { throw HopperError("session already runs on \(to)") }
        }
        let move = PendingMove(to: to ?? PendingMove.anywhere, trigger: now ? "now" : "confirm", source: source)
        let f = env.paths.session(s.record.session)
        try FileIO.encode(move, to: now ? f.ctl : f.pending)
        FileIO.remove(f.suggest)
        return s
    }

    /// "Not now": keep the suggestion out of the way until something changes.
    public static func dismiss(session id: String, env: HopperEnvironment) {
        guard let s = Sessions.find(id, env.paths), var sug = s.suggestion else { return }
        sug.dismissed = true
        try? FileIO.encode(sug, to: env.paths.session(s.record.session).suggest)
    }

    public static func setHold(session id: String?, on: Bool, env: HopperEnvironment) throws {
        let url: URL
        if let id {
            guard let s = Sessions.find(id, env.paths) else { throw HopperError("no live session \(id)") }
            url = env.paths.session(s.record.session).hold
            // A hold cancels what the engine queued on its own; a move the user confirmed stays.
            if on, let p = s.pending, ["park", "auto"].contains(p.trigger) {
                FileIO.remove(env.paths.session(s.record.session).pending)
            }
        } else {
            url = env.paths.holdAll
        }
        if on { FileIO.touch(url) } else { FileIO.remove(url) }
    }
}
