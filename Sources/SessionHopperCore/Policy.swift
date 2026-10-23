import Foundation

/// What the supervisor should do about the profile a session runs on.
public enum Decision: Equatable, Sendable {
    case none
    /// Ask the user (default): another profile has room.
    case suggest(to: String, percent: Double)
    /// Opt-in "move without asking": queue the move for the next turn end.
    case autoMove(to: String, percent: Double)
    /// Past the hard threshold with nowhere to move (or moving not allowed): end at the next turn end.
    case park(percent: Double)
}

/// Pure threshold logic. Usage is only what Claude Code's own status line reported; a profile with
/// no sample, or whose windows all reset since, is "unknown" and counts as having room.
public struct Policy: Sendable {
    public var config: HopperConfig
    public var limits: [String: ProfileLimits]
    public var now: Double

    public init(config: HopperConfig, limits: [String: ProfileLimits], now: Double) {
        self.config = config
        self.limits = limits
        self.now = now
    }

    public func percent(_ profile: String) -> Double? { limits[profile]?.percent(now: now) }

    func hasRoom(_ profile: String, under limit: Double) -> Bool { (percent(profile) ?? 0) < limit }

    /// First profile in `order` under `limit`.
    public func first(in order: [Profile], under limit: Double, excluding: String? = nil) -> Profile? {
        order.first { $0.name != excluding && hasRoom($0.name, under: limit) }
    }

    /// Where to (re)start: order beats headroom, so the preferred profile is used up first. A profile under
    /// the suggest threshold wins over one between the thresholds, which would only queue the next move.
    public func pick(_ order: [Profile], excluding: String? = nil) -> Profile? {
        first(in: order, under: config.suggestThreshold, excluding: excluding)
            ?? first(in: order, under: config.hardThreshold, excluding: excluding)
    }

    /// `held`: the user pinned this session to its profile; it is never parked or moved automatically.
    public func evaluate(current: Profile, order: [Profile], held: Bool) -> Decision {
        guard let pct = percent(current.name) else { return .none }
        let roomy = first(in: order, under: config.suggestThreshold, excluding: current.name)
        if !held, pct >= config.hardThreshold {
            if config.autoMove, let to = roomy ?? first(in: order, under: config.hardThreshold, excluding: current.name) {
                return .autoMove(to: to.name, percent: pct)
            }
            if config.parkBeforePaid { return .park(percent: pct) }
        }
        guard pct >= config.suggestThreshold, let to = roomy else { return .none }
        return config.autoMove && !held ? .autoMove(to: to.name, percent: pct) : .suggest(to: to.name, percent: pct)
    }
}
