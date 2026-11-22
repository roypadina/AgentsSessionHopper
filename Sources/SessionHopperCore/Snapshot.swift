import Foundation

/// Everything `status` and the menu-bar app show, read from the state directory in one go.
public struct HopperSnapshot: Codable, Equatable, Sendable {
    public var config: HopperConfig
    public var limits: [String: ProfileLimits]
    public var sessions: [LiveSession]
    public var events: [HopperEvent]
    public var now: Double
    /// Profile name → login email, for profiles where Claude Code's `.claude.json` has one.
    public var emails: [String: String]

    public init(config: HopperConfig, limits: [String: ProfileLimits], sessions: [LiveSession], events: [HopperEvent], now: Double,
                emails: [String: String] = [:]) {
        self.config = config
        self.limits = limits
        self.sessions = sessions
        self.events = events
        self.now = now
        self.emails = emails
    }

    public static func load(_ paths: StatePaths, home: URL, events n: Int = 5) -> HopperSnapshot {
        let config = HopperConfig.load(paths)
        var emails: [String: String] = [:]   // a loop, not uniqueKeysWithValues: a hand-edited config may repeat a name
        for p in config.profiles where emails[p.name] == nil { emails[p.name] = Profiles.email(of: p, home: home) }
        return HopperSnapshot(config: config, limits: LimitStore.all(config, paths), sessions: Sessions.live(paths),
                              events: EventLog.read(paths, last: n), now: FileIO.now(), emails: emails)
    }

    public func sessions(on profile: String) -> [LiveSession] { sessions.filter { $0.record.profile == profile } }

    public func percent(_ profile: String) -> Double? { limits[profile]?.percent(now: now) }

    /// Highest usage among profiles that have live sessions (for the menu-bar label).
    public var worstLivePercent: Double? {
        Set(sessions.map(\.record.profile)).compactMap { percent($0) }.max()
    }

    public var needsAttention: [LiveSession] { sessions.filter { ($0.suggestion.map { !$0.dismissed } ?? false) && $0.pending == nil } }
}

public enum HopperInfo {
    public static let version = "1.15.0"
    public static let repo = URL(string: "https://github.com/roypadina/AgentsSessionHopper")!
    public static let koFi = URL(string: "https://ko-fi.com/roypadina")!
    public static let disclaimer = "AgentsSessionHopper is an independent open-source tool. It is not made by, affiliated with, or endorsed by Anthropic. Claude and Claude Code are trademarks of Anthropic, PBC."
}
