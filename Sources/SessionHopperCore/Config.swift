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
    /// nil or "claude": a Claude login. "openrouter": the same `claude`, billed to an OpenRouter key (see `Gateway`).
    public var kind: String?
    /// Gateway profiles: where the API key is read from, instead of the platform default (see `Gateway.key`).
    public var keyFile: String?
    /// Gateway profiles: Claude Code model alias (opus, sonnet, haiku, fable) → the gateway's model name.
    public var models: [String: String]?
    /// Gateway profiles: Anthropic-compatible endpoint. Default `Gateway.openRouterURL`.
    public var baseURL: String?
    /// Gateway profiles: when a spent key has credit again: daily | weekly | monthly (UTC). Default daily.
    public var resets: String?
    /// Lower is preferred (see `Policy.priority` for the default). Equal priorities don't trade places before a limit.
    public var priority: Int?

    public var id: String { name }
    /// Billed per use (an API key), not a subscription: used only when no subscription profile has room.
    public var isGateway: Bool { kind == Gateway.openRouter }

    public init(name: String, dir: String, exportConfigDir: Bool, kind: String? = nil, keyFile: String? = nil,
                models: [String: String]? = nil, baseURL: String? = nil, resets: String? = nil, priority: Int? = nil) {
        self.name = name
        self.dir = dir
        self.exportConfigDir = exportConfigDir
        self.kind = kind
        self.keyFile = keyFile
        self.models = models
        self.baseURL = baseURL
        self.resets = resets
        self.priority = priority
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
    /// When every profile is full, wait for the first known window reset and carry on there, instead of
    /// exiting. Nothing is billed while waiting.
    public var waitForReset: Bool = true
    /// The user's own continue prompt (placeholders: see `LaunchPlan.defaultContinuePrompt`). nil = built-in.
    public var continuePrompt: String?
    /// When pay-per-use (gateway) profiles are used: `last` only once every subscription profile is full,
    /// `order` by their place in the list like any profile, `manual` only when asked for (`-P`, `switch`).
    public var gatewayUse: String = "last"
    public static let gatewayUses = ["last", "order", "manual"]
    /// A shell command run (not waited for) on every move, limit stop and park, with `SESSIONHOPPER_EVENT`,
    /// `_FROM`, `_TO`, `_REASON`, `_DETAIL` and `_SESSION` set. nil = none.
    public var onSwitch: String?

    public init() {}

    enum CodingKeys: String, CodingKey { case profiles, suggestThreshold, hardThreshold, autoMove, parkBeforePaid, moveNowAtHard, waitForReset, continuePrompt, gatewayUse, onSwitch }

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
        waitForReset = try c.decodeIfPresent(Bool.self, forKey: .waitForReset) ?? d.waitForReset
        continuePrompt = try c.decodeIfPresent(String.self, forKey: .continuePrompt)
        gatewayUse = try c.decodeIfPresent(String.self, forKey: .gatewayUse) ?? d.gatewayUse
        onSwitch = try c.decodeIfPresent(String.self, forKey: .onSwitch)
    }

    public static func load(_ paths: StatePaths) -> HopperConfig {
        FileIO.decode(HopperConfig.self, from: paths.config) ?? HopperConfig()
    }

    public func save(_ paths: StatePaths) throws {
        guard suggestThreshold > 0, suggestThreshold < hardThreshold, hardThreshold <= 100 else {
            throw HopperError("thresholds must satisfy 0 < suggest (\(Int(suggestThreshold))) < hard (\(Int(hardThreshold))) <= 100")
        }
        guard Self.gatewayUses.contains(gatewayUse) else { throw HopperError("gateway use is one of: \(Self.gatewayUses.joined(separator: ", "))") }
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
