import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What an alert is about. Each one is switched on or off per profile and per channel (`AlertSettings`).
public enum AlertKind: String, CaseIterable, Codable, Sendable {
    /// Sessions left a profile on their own (limit, login, threshold) and continue on another one.
    case switched = "switch"
    /// No profile has room: a session waits for a reset or stopped.
    case noRoom = "no-room"
    /// A profile passed the suggest threshold (`HopperConfig.suggestThreshold`).
    case usageWarning = "usage-warning"
    /// A profile passed the park threshold (`HopperConfig.hardThreshold`).
    case usageCritical = "usage-critical"

    public var label: String {
        switch self {
        case .switched: return "Moved to another profile"
        case .noRoom: return "No profile has room"
        case .usageWarning: return "Usage warning"
        case .usageCritical: return "Usage critical"
        }
    }
    /// ntfy priority: high for the ones that need a look, default for the early warning. Never urgent.
    var priority: Int { self == .usageWarning ? 3 : 4 }
}

/// One profile's setting for one kind. nil fields fall back to the "*" (every profile) rule, then the default.
public struct AlertRule: Codable, Equatable, Sendable {
    public var mac: Bool?
    public var ntfy: Bool?
    /// Usage alerts only while a session on this Mac runs on the profile (an account also used elsewhere
    /// can fill up with nobody here affected).
    public var activeOnly: Bool?
    public init(mac: Bool? = nil, ntfy: Bool? = nil, activeOnly: Bool? = nil) { self.mac = mac; self.ntfy = ntfy; self.activeOnly = activeOnly }
}

public struct AlertSettings: Codable, Equatable, Sendable {
    /// ntfy server root (`https://ntfy.sh` or your own) and topic. Both set = ntfy on. The access token, if any,
    /// is kept like a profile key (Keychain on macOS, private file on Linux), never here.
    public var ntfyServer: String?
    public var ntfyTopic: String?
    /// profile name (or `AlertSettings.everyProfile`) → kind → rule.
    public var rules: [String: [String: AlertRule]] = [:]
    public static let everyProfile = "*"

    public init() {}

    public var ntfyOn: Bool { !(ntfyServer ?? "").isEmpty && !(ntfyTopic ?? "").isEmpty }

    public struct Effective: Equatable, Sendable {
        public var mac: Bool, ntfy: Bool, activeOnly: Bool
    }

    /// Defaults: a Mac notification when no profile has room (what the app always did), nothing else;
    /// usage alerts only for profiles a session here runs on.
    public func effective(_ profile: String, _ kind: AlertKind) -> Effective {
        let own = rules[profile]?[kind.rawValue], any = rules[Self.everyProfile]?[kind.rawValue]
        return Effective(mac: own?.mac ?? any?.mac ?? (kind == .noRoom),
                         ntfy: own?.ntfy ?? any?.ntfy ?? false,
                         activeOnly: own?.activeOnly ?? any?.activeOnly ?? true)
    }

    /// Setting "*" clears the same field on every profile, so "all" means all.
    public mutating func set(_ profile: String, _ kind: AlertKind, mac: Bool? = nil, ntfy: Bool? = nil, activeOnly: Bool? = nil) {
        if profile == Self.everyProfile {
            for p in rules.keys where p != profile {
                if mac != nil { rules[p]?[kind.rawValue]?.mac = nil }
                if ntfy != nil { rules[p]?[kind.rawValue]?.ntfy = nil }
                if activeOnly != nil { rules[p]?[kind.rawValue]?.activeOnly = nil }
            }
        }
        var r = rules[profile]?[kind.rawValue] ?? AlertRule()
        if let mac { r.mac = mac }
        if let ntfy { r.ntfy = ntfy }
        if let activeOnly { r.activeOnly = activeOnly }
        rules[profile, default: [:]][kind.rawValue] = r
    }
}

/// One alert that fired, a line of `alerts.jsonl`. The app shows the `mac` ones; `sessionhopper alerts deliver`
/// sends the `ntfy` ones.
public struct AlertRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var ts: String
    public var kind: String
    public var profile: String
    public var title: String
    public var body: String
    public var mac: Bool
    public var ntfy: Bool
}

/// Decides which events and usage samples become alerts. Every session, hook and the app call it, so the decision
/// and its memory live in the state dir under a lock: many sessions on one profile moving at once give one alert.
/// - a move off a profile: one alert, then quiet until that profile's blocking window resets
/// - no profile has room: one alert, then quiet until the first profile frees up
/// - a usage threshold: once per profile, window and level (critical also covers the warning)
public enum Alerts {
    /// Claude Code's reset times jitter by a second or two between samples; a window closer than this is the same one.
    static let windowTolerance: Double = 120
    /// Quiet time when no reset time is known.
    static let cooldown: Double = 3600

    struct Memory: Codable, Equatable {
        /// switch / no-room: quiet until then.
        var until: Double?
        /// usage: the window (its reset time) already alerted.
        var window: Double?
    }

    // MARK: - Triggers

    /// A `switch`, `run` (served after a retry) or `park` event from the engine.
    public static func event(_ e: HopperEvent, env: HopperEnvironment, now: Double = Date().timeIntervalSince1970) {
        let config = HopperConfig.load(env.paths)
        let userSources: Set<String> = ["menu", "cli", "notification"]
        switch e.type {
        case "switch", "run":
            // A move the user asked for is not news.
            guard let from = e.from, let to = e.to, from != to, !userSources.contains(e.source ?? "") else { return }
            let limits = LimitStore.read(from, env.paths)
            let until = blockedUntil(limits, threshold: config.suggestThreshold, now: now) ?? now + cooldown
            let why: String
            switch e.trigger ?? "" {
            case "limit_stop", "limit": why = "hit its usage limit"
            case "login_stop", "login": why = "could not run (login expired or account blocked)"
            default: why = "is near its usage limit" + (limits?.percent(now: now).map { " (\(Int($0.rounded()))%)" } ?? "")
            }
            fire(.switched, profile: from, key: "switch|\(from)", config: config, env: env, now: now, active: true,
                 title: "\(config.display(from)) → \(config.display(to))",
                 body: "\(config.display(from)) \(why). Sessions continue on \(config.display(to)). More moves off \(config.display(from)) stay quiet until \(ProfileLimits.clock(until)).") { old in
                (old?.until ?? 0) > now ? nil : Memory(until: until)
            }
        case "park":
            let from = e.from ?? AlertSettings.everyProfile
            let until = config.profiles.filter { !$0.isGateway }
                .compactMap { blockedUntil(LimitStore.read($0.name, env.paths), threshold: config.hardThreshold, now: now) }.min() ?? now + cooldown
            fire(.noRoom, profile: from, key: "no-room", config: config, env: env, now: now, active: true,
                 title: "No profile has room",
                 body: (e.detail.map { "A session is \($0)." } ?? "A session stopped: every profile is full.") + " More of these stay quiet until \(ProfileLimits.clock(until)).") { old in
                (old?.until ?? 0) > now ? nil : Memory(until: until)
            }
        default:
            return
        }
    }

    /// After a new usage sample for `profile` (status line, refresh, `run`).
    public static func usage(_ profile: String, env: HopperEnvironment, now: Double = Date().timeIntervalSince1970) {
        let config = HopperConfig.load(env.paths)
        guard let p = config.profile(named: profile), !p.isGateway, let l = LimitStore.read(profile, env.paths) else { return }
        let active = Sessions.live(env.paths).contains { $0.record.profile == profile }
        let windows: [(String, String, LimitWindow?)] = [("5h", "5-hour", l.fiveHour), ("7d", "weekly", l.sevenDay)]
        for (kind, threshold) in [(AlertKind.usageCritical, config.hardThreshold), (.usageWarning, config.suggestThreshold)] {
            for (short, name, w) in windows {
                guard let w, w.isLive(now: now), w.usedPercentage >= threshold else { continue }
                let reset = w.resetsAt ?? 0
                let seen: (Memory?) -> Bool = { m in m?.window.map { abs($0 - reset) < windowTolerance } ?? false }
                // A critical alert for this window already said more than the warning would.
                if kind == .usageWarning, seen(memory(env.paths)["\(AlertKind.usageCritical.rawValue)|\(profile)|\(short)"]) { continue }
                fire(kind, profile: profile, key: "\(kind.rawValue)|\(profile)|\(short)", config: config, env: env, now: now, active: active,
                     title: "\(config.display(profile)): \(Int(w.usedPercentage.rounded()))% of its \(name) limit",
                     body: "\(config.display(profile)) passed \(Int(threshold))% of its \(name) usage" + (w.resetsAt.map { ", resets \(ProfileLimits.clock($0))" } ?? "") + ".") { old in
                    seen(old) ? nil : Memory(window: reset)
                }
            }
        }
    }

    /// The latest reset among the windows at or over `threshold`: until then the profile stays blocked. nil = none over.
    static func blockedUntil(_ l: ProfileLimits?, threshold: Double, now: Double) -> Double? {
        [l?.fiveHour, l?.sevenDay].compactMap { $0 }.filter { $0.isLive(now: now) && $0.usedPercentage >= threshold }
            .compactMap(\.resetsAt).max()
    }

    // MARK: - Firing

    /// Under the lock: skips a kind switched off for this profile (or off while no session runs on it), asks `decide`
    /// whether the memory says it is new, records it and queues delivery.
    static func fire(_ kind: AlertKind, profile: String, key: String, config: HopperConfig, env: HopperEnvironment, now: Double,
                     active: Bool, title: String, body: String, decide: (Memory?) -> Memory?) {
        let rule = config.alerts.effective(profile, kind)
        let ntfy = rule.ntfy && config.alerts.ntfyOn
        guard rule.mac || ntfy, active || !rule.activeOnly else { return }
        let record: AlertRecord? = locked(env.paths) {
            var mem = memory(env.paths)
            guard let next = decide(mem[key]) else { return nil }
            mem[key] = next
            try? FileIO.encode(mem, to: env.paths.alertMemory)
            let r = AlertRecord(id: eventID(now: now), ts: FileIO.isoNow(), kind: kind.rawValue, profile: profile,
                                title: title, body: body, mac: rule.mac, ntfy: ntfy)
            append(r, env.paths)
            return r
        }
        if let record, record.ntfy { deliverDetached(record, env: env) }
    }

    /// A test alert on every channel that is set up, past the memory.
    @discardableResult
    public static func test(env: HopperEnvironment) -> AlertRecord {
        let config = HopperConfig.load(env.paths)
        let r = AlertRecord(id: eventID(now: FileIO.now()), ts: FileIO.isoNow(), kind: "test", profile: AlertSettings.everyProfile,
                            title: "AgentsSessionHopper test alert", body: "Alerts reach you here.", mac: true, ntfy: config.alerts.ntfyOn)
        append(r, env.paths)
        return r
    }

    static func memory(_ paths: StatePaths) -> [String: Memory] { FileIO.decode([String: Memory].self, from: paths.alertMemory) ?? [:] }

    static func append(_ r: AlertRecord, _ paths: StatePaths) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(r), let line = String(data: data, encoding: .utf8) else { return }
        FileIO.appendLine(line, to: paths.alerts)
    }

    /// Newest last.
    public static func read(_ paths: StatePaths, last n: Int = 200) -> [AlertRecord] {
        guard let text = FileIO.readString(paths.alerts) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").suffix(n).compactMap { try? dec.decode(AlertRecord.self, from: Data($0.utf8)) }
    }

    /// `YYYYMMDD-HHMMSS-<4 hex>`, also the ntfy footer's `event`.
    static func eventID(now: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date(timeIntervalSince1970: now)) + "-" + String(format: "%04x", UInt16.random(in: 0...UInt16.max))
    }

    static func locked<T>(_ paths: StatePaths, _ body: () -> T) -> T {
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let fd = open(paths.root.appendingPathComponent(".alerts.lock").path, O_RDWR | O_CREAT, 0o600)
        defer { if fd >= 0 { close(fd) } }
        // shortcut: on a lock that can't be opened it decides unlocked; a duplicate alert is the worst case.
        if fd >= 0 { _ = flock(fd, LOCK_EX) }
        return body()
    }

    // MARK: - ntfy

    /// The ntfy access token is stored like a profile key under this name (no profile can be called that).
    public static let tokenEntry = Profile(name: ".ntfy", dir: "", exportConfigDir: false)

    /// Sending waits on the network, so a session, hook or status line never does it itself: a detached
    /// `sessionhopper alerts deliver <id>` does.
    static func deliverDetached(_ r: AlertRecord, env: HopperEnvironment) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: env.selfPath)
        p.arguments = ["alerts", "deliver", r.id]
        p.environment = env.vars
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// Posts `r` to the configured ntfy topic. Returns the HTTP status (nil = no answer).
    public static func sendNtfy(_ r: AlertRecord, env: HopperEnvironment) -> Int? {
        let s = HopperConfig.load(env.paths).alerts
        guard s.ntfyOn, let server = s.ntfyServer, let url = URL(string: server) else { return nil }
        let host = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "host"
        let payload: [String: Any] = [
            "topic": s.ntfyTopic ?? "", "title": r.title, "priority": AlertKind(rawValue: r.kind)?.priority ?? 3,
            "tags": ["agents-session-hopper", r.kind],
            "message": "\(r.body)\n\nsender: agents-session-hopper@\(host)\nflow: \(r.kind)\nevent: \(r.id)"
        ]
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = try? Gateway.key(tokenEntry, env: env) { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var status: Int?
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            status = (resp as? HTTPURLResponse)?.statusCode
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 20)
        return status
    }

    /// ntfy topics: letters, digits, - and _ (max 64).
    public static func validTopic(_ t: String) -> Bool {
        !t.isEmpty && t.count <= 64 && t.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
