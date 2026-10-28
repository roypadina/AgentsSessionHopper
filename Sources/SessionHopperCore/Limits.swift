import Foundation

/// One rate-limit window as Claude Code reports it to its status line:
/// `rate_limits.five_hour` / `rate_limits.seven_day` with `used_percentage` (0-100) and `resets_at`
/// (epoch seconds). Present only for Pro/Max subscribers and only after the first API response;
/// each window may be absent (https://code.claude.com/docs/en/statusline, "Rate limit usage").
public struct LimitWindow: Codable, Equatable, Sendable {
    public var usedPercentage: Double
    public var resetsAt: Double?

    public init(usedPercentage: Double, resetsAt: Double?) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }

    /// A window whose reset time has passed no longer says anything about the account.
    public func isLive(now: Double) -> Bool { resetsAt.map { $0 > now } ?? true }

    init?(_ any: Any?) {
        guard let obj = any as? [String: Any], let pct = (obj["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
        self.init(usedPercentage: pct, resetsAt: (obj["resets_at"] as? NSNumber)?.doubleValue)
    }
}

/// Last-known limits of one profile, from whichever of its sessions rendered a status line last.
public struct ProfileLimits: Codable, Equatable, Sendable {
    public var fiveHour: LimitWindow?
    public var sevenDay: LimitWindow?
    /// Behind a Claude apps gateway: how much of the user's spend limit is used. Past it is paid usage,
    /// so it counts like an account window.
    public var spendLimit: LimitWindow?
    public var sampledAt: Double
    public var session: String?

    public init(fiveHour: LimitWindow?, sevenDay: LimitWindow?, spendLimit: LimitWindow? = nil, sampledAt: Double, session: String? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.spendLimit = spendLimit
        self.sampledAt = sampledAt
        self.session = session
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case spendLimit = "spend_limit"
        case sampledAt = "sampled_at"
        case session
    }

    /// From the status-line JSON; nil when it carries no `rate_limits` window (not a subscriber, or no
    /// API response yet).
    public static func fromStatusLine(_ json: [String: Any], now: Double) -> ProfileLimits? {
        guard let rl = json["rate_limits"] as? [String: Any] else { return nil }
        let five = LimitWindow(rl["five_hour"]), week = LimitWindow(rl["seven_day"]), spend = LimitWindow(rl["spend_limit"])
        guard five != nil || week != nil || spend != nil else { return nil }
        return ProfileLimits(fiveHour: five, sevenDay: week, spendLimit: spend, sampledAt: now, session: json["session_id"] as? String)
    }

    private var windows: [(name: String, window: LimitWindow)] {
        [("5h", fiveHour), ("7d", sevenDay), ("spend", spendLimit)].compactMap { name, w in w.map { (name, $0) } }
    }

    /// The fullest window that has not reset since the sample, or nil when nothing is known.
    public func blocking(now: Double) -> (name: String, window: LimitWindow)? {
        windows.filter { $0.window.isLive(now: now) }.max { $0.window.usedPercentage < $1.window.usedPercentage }
    }

    public func percent(now: Double) -> Double? { blocking(now: now)?.window.usedPercentage }

    /// When this profile is under `limit` again: the latest reset among its windows at or past it.
    /// nil when one of those windows has no reset time.
    public func freeAt(under limit: Double, now: Double) -> Double? {
        let resets = windows.filter { $0.window.isLive(now: now) && $0.window.usedPercentage >= limit }.map(\.window.resetsAt)
        return resets.contains(nil) ? nil : resets.compactMap { $0 }.max() ?? now
    }

    /// A sample older than this is shown with its age.
    public static let staleAfter: Double = 600

    /// "resets Thu 14:00 · sampled 3 h ago": when the fullest window resets, and the sample's age once it is stale.
    public func note(now: Double) -> String {
        var parts: [String] = []
        if let w = blocking(now: now) {
            if let r = w.window.resetsAt { parts.append("resets \(Self.clock(r))") }
        } else {
            parts.append("reset since last seen")
        }
        if now - sampledAt >= Self.staleAfter { parts.append("sampled \(Self.age(now - sampledAt)) ago") }
        return parts.joined(separator: " · ")
    }

    /// "5h 98% · resets 14:00 · sampled 3 h ago"; "unknown" without a sample.
    public static func label(_ l: ProfileLimits?, now: Double) -> String {
        guard let l else { return "unknown" }
        let pct = l.blocking(now: now).map { "\($0.name) \(Int($0.window.usedPercentage.rounded()))%" }
        return [pct, l.note(now: now)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public static func clock(_ epoch: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(Date(timeIntervalSince1970: epoch)) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: Date(timeIntervalSince1970: epoch))
    }

    static func age(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        return m < 90 ? "\(m) min" : m < 48 * 60 ? "\(m / 60) h" : "\(m / 1440) d"
    }
}

public enum LimitStore {
    public static func read(_ profile: String, _ paths: StatePaths) -> ProfileLimits? {
        FileIO.decode(ProfileLimits.self, from: paths.limits(profile))
    }

    public static func write(_ limits: ProfileLimits, profile: String, _ paths: StatePaths) throws {
        try FileIO.encode(limits, to: paths.limits(profile))
    }

    public static func all(_ config: HopperConfig, _ paths: StatePaths) -> [String: ProfileLimits] {
        var out: [String: ProfileLimits] = [:]
        for p in config.profiles { out[p.name] = read(p.name, paths) }
        return out
    }
}
