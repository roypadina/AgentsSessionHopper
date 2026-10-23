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
    public var sampledAt: Double
    public var session: String?

    public init(fiveHour: LimitWindow?, sevenDay: LimitWindow?, sampledAt: Double, session: String? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sampledAt = sampledAt
        self.session = session
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sampledAt = "sampled_at"
        case session
    }

    /// From the status-line JSON; nil when it carries no `rate_limits` window (not a subscriber, or no
    /// API response yet). `spend_limit` (gateway spend caps) is not an account window and is ignored.
    public static func fromStatusLine(_ json: [String: Any], now: Double) -> ProfileLimits? {
        guard let rl = json["rate_limits"] as? [String: Any] else { return nil }
        let five = LimitWindow(rl["five_hour"]), week = LimitWindow(rl["seven_day"])
        guard five != nil || week != nil else { return nil }
        return ProfileLimits(fiveHour: five, sevenDay: week, sampledAt: now, session: json["session_id"] as? String)
    }

    /// The fullest window that has not reset since the sample, or nil when nothing is known.
    public func blocking(now: Double) -> (name: String, window: LimitWindow)? {
        [("5h", fiveHour), ("7d", sevenDay)]
            .compactMap { name, w in w.flatMap { $0.isLive(now: now) ? (name, $0) : nil } }
            .max { $0.1.usedPercentage < $1.1.usedPercentage }
    }

    public func percent(now: Double) -> Double? { blocking(now: now)?.window.usedPercentage }
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
