import Foundation

/// One Claude Code profile: a configuration directory with its own login.
/// Claude Code's documented way to run several accounts side by side is one `CLAUDE_CONFIG_DIR`
/// per account (https://code.claude.com/docs/en/authentication, "Log in with multiple accounts").
public struct Profile: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    /// Absolute path of the configuration directory.
    public var dir: String
    /// Set `CLAUDE_CONFIG_DIR` when launching. Off by default for `~/.claude`: setting it, even to the
    /// default path, makes Claude Code look for a differently named login and asks you to log in again.
    /// Turn it on if you always launch that profile with the variable set.
    public var exportConfigDir: Bool

    public var id: String { name }

    public init(name: String, dir: String, exportConfigDir: Bool) {
        self.name = name
        self.dir = dir
        self.exportConfigDir = exportConfigDir
    }
}

public struct HopperConfig: Codable, Equatable, Sendable {
    /// Fallback order: the first profile with room is used.
    public var profiles: [Profile] = []
    /// Suggest a hand-off from this percentage of the fullest window.
    public var suggestThreshold: Double = 85
    /// Past this, park the session at its next turn end (if `parkBeforePaid`).
    public var hardThreshold: Double = 97
    /// Opt-in: move at turn end without asking. Off by default.
    public var autoMove: Bool = false
    /// End the session at its next turn end past the hard threshold, instead of running into paid usage.
    public var parkBeforePaid: Bool = true
    /// Opt-in: past the hard threshold an automatic move or park happens at once, even mid-turn, instead of
    /// at the next turn end (a long turn could otherwise run past 100%). Held sessions are never cut into.
    public var moveNowAtHard: Bool = false

    public init() {}

    enum CodingKeys: String, CodingKey { case profiles, suggestThreshold, hardThreshold, autoMove, parkBeforePaid, moveNowAtHard }

    // Missing keys keep their defaults, so older config files keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HopperConfig()
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? d.profiles
        suggestThreshold = try c.decodeIfPresent(Double.self, forKey: .suggestThreshold) ?? d.suggestThreshold
        hardThreshold = try c.decodeIfPresent(Double.self, forKey: .hardThreshold) ?? d.hardThreshold
        autoMove = try c.decodeIfPresent(Bool.self, forKey: .autoMove) ?? d.autoMove
        parkBeforePaid = try c.decodeIfPresent(Bool.self, forKey: .parkBeforePaid) ?? d.parkBeforePaid
        moveNowAtHard = try c.decodeIfPresent(Bool.self, forKey: .moveNowAtHard) ?? d.moveNowAtHard
    }

    public static func load(_ paths: StatePaths) -> HopperConfig {
        FileIO.decode(HopperConfig.self, from: paths.config) ?? HopperConfig()
    }

    public func save(_ paths: StatePaths) throws {
        guard suggestThreshold > 0, suggestThreshold < hardThreshold, hardThreshold <= 100 else {
            throw HopperError("thresholds must satisfy 0 < suggest (\(Int(suggestThreshold))) < hard (\(Int(hardThreshold))) <= 100")
        }
        try FileIO.encode(self, to: paths.config)
    }

    public func profile(named name: String) -> Profile? { profiles.first { $0.name == name } }

    /// `prefer` moves to the front, the rest keep their order behind it; `only` drops the rest.
    public func order(prefer: [String], only: Bool) throws -> [Profile] {
        for name in prefer where profile(named: name) == nil {
            throw HopperError("unknown profile '\(name)' (known: \(profiles.map(\.name).joined(separator: ", ")))")
        }
        let front = prefer.compactMap { profile(named: $0) }
        return only ? front : front + profiles.filter { !prefer.contains($0.name) }
    }
}

public struct HopperError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
