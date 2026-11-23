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

    /// A paused profile counts as full (100%): nothing lands there and its sessions move off at turn end.
    public func percent(_ profile: String) -> Double? {
        paused(profile) ? 100 : limits[profile]?.percent(now: now)
    }

    public func paused(_ profile: String) -> Bool { config.profile(named: profile)?.isPaused(now: now) ?? false }

    func hasRoom(_ profile: String, under limit: Double) -> Bool { (percent(profile) ?? 0) < limit }

    /// First profile in `order` under `limit` (a profile's own threshold: `config.suggest` or `config.hard`).
    public func first(in order: [Profile], under limit: (String) -> Double, excluding: String? = nil) -> Profile? {
        order.first { $0.name != excluding && hasRoom($0.name, under: limit($0.name)) }
    }

    /// Lower is preferred. Unset: Claude profiles 1, gateway (pay-per-use) profiles 10, or 1 with `gateway order`.
    public func priority(_ p: Profile) -> Int { p.priority ?? (p.isGateway && config.gatewayUse != "order" ? 10 : 1) }

    /// What the policy may choose by itself: with `gateway manual`, gateways only when `order` holds nothing else.
    func automatic(_ order: [Profile]) -> [Profile] {
        guard config.gatewayUse == "manual", order.contains(where: { !$0.isGateway }) else { return order }
        return order.filter { !$0.isGateway }
    }

    /// Priority levels, best first; `order` kept inside each.
    func levels(_ order: [Profile]) -> [[Profile]] {
        Dictionary(grouping: automatic(order), by: priority).sorted { $0.key < $1.key }.map(\.value)
    }

    /// Where to (re)start. The best priority level with room wins. Inside a level, `current` (the profile already in
    /// use) stays until it reaches the hard threshold, so profiles of equal priority never trade places early;
    /// otherwise order beats headroom, and a profile under the suggest threshold wins over one between the thresholds.
    public func pick(_ order: [Profile], excluding: String? = nil, current: String? = nil) -> Profile? {
        for level in levels(order) {
            if let cur = current, cur != excluding, let p = level.first(where: { $0.name == cur }),
               hasRoom(cur, under: config.hard(cur)) { return p }
            if let p = first(in: level, under: config.suggest, excluding: excluding)
                ?? first(in: level, under: config.hard, excluding: excluding) { return p }
        }
        return nil
    }

    /// `held`: the user pinned this session to its profile; it is never parked or moved automatically.
    public func evaluate(current: Profile, order: [Profile], held: Bool) -> Decision {
        // Paused by the user: move off like a full profile, asked or automatic per "move without asking"; park only
        // when nothing else has room. A held session stays.
        if !held, paused(current.name) {
            if let to = pick(order, excluding: current.name) { return config.autoMove ? .autoMove(to: to.name, percent: 100) : .suggest(to: to.name, percent: 100) }
            return config.parkBeforePaid ? .park(percent: 100) : .none
        }
        // A profile of better priority has room again: go back up (pay-per-use to Claude, a fallback account to the main ones).
        if let up = levels(order).joined().first(where: { priority($0) < priority(current) && hasRoom($0.name, under: config.suggest($0.name)) }) {
            let pct = percent(current.name) ?? 0
            return config.autoMove && !held ? .autoMove(to: up.name, percent: pct) : .suggest(to: up.name, percent: pct)
        }
        // Near the limit: another profile of the same priority. Lower levels only past the hard threshold (`pick`).
        let peers = automatic(order).filter { priority($0) == priority(current) }
        let roomy = first(in: peers, under: config.suggest, excluding: current.name)
        guard let pct = percent(current.name) else { return .none }
        if !held, pct >= config.hard(current.name) {
            if config.autoMove, let to = pick(order, excluding: current.name) {
                return .autoMove(to: to.name, percent: pct)
            }
            if config.parkBeforePaid { return .park(percent: pct) }
        }
        guard pct >= config.suggest(current.name), let to = roomy else { return .none }
        return config.autoMove && !held ? .autoMove(to: to.name, percent: pct) : .suggest(to: to.name, percent: pct)
    }

    /// `moveNowAtHard`: an automatic move or park past the hard threshold happens at once, not at the turn end.
    public func isUrgent(_ d: Decision, current: Profile) -> Bool {
        // A pause waits for the turn end, like a confirmed move.
        guard config.moveNowAtHard, !paused(current.name), let pct = percent(current.name), pct >= config.hard(current.name) else { return false }
        switch d {
        case .autoMove, .park: return true
        default: return false
        }
    }

    /// Profiles ahead of `chosen` in `order` that were passed over, with their usage ("work 5h 98% · resets 14:00").
    public func skipped(_ order: [Profile], before chosen: Profile) -> [String] {
        order.prefix { $0.name != chosen.name }.map { p in "\(p.name) \(ProfileLimits.label(limits[p.name], now: now))" }
    }

    /// Every profile is full: the one whose windows reset first, and when. nil = none has a known reset.
    public func nextRoom(_ order: [Profile]) -> (profile: Profile, at: Double)? {
        order.compactMap { p -> (Profile, Double)? in
            let free = limits[p.name]?.freeAt(under: config.hard(p.name), now: now) ?? (paused(p.name) ? now : nil)
            guard let free else { return nil }
            // shortcut: "forever" has no end to wait for.
            if let until = config.profile(named: p.name)?.pausedUntil, until > now { return until >= Profile.pausedForever ? nil : (p, max(free, until)) }
            return (p, free)
        }
            .min { $0.1 < $1.1 }
    }
}
