import Foundation

/// Fresh usage for profiles no session has reported on lately. A sample only comes from a session running on
/// that profile, so an idle profile kept its last numbers for days (and a limit reset on the account's page went
/// unseen). One tiny `claude -p` on the cheapest model prints a `rate_limit_event` with both windows.
public enum UsageRefresh {
    /// Samples older than this are refreshed by the app (and `refresh --stale`).
    public static let maxAge: Double = 6 * 3600

    /// Claude profiles (gateways have no plan windows) with no sample, or one older than `maxAge`.
    public static func due(_ config: HopperConfig, limits: [String: ProfileLimits], now: Double) -> [Profile] {
        config.profiles.filter { p in !p.isGateway && (limits[p.name].map { now - $0.sampledAt >= maxAge } ?? true) }
    }

    /// The probe: no tools, no MCP, no settings (hooks, plugins), no saved transcript, run in a scratch folder.
    static let args = ["-p", "--model", "haiku", "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                       "--no-session-persistence", "--max-turns", "1", "--output-format", "stream-json", "--verbose"]

    /// Refreshes `profiles` one by one and stores what each run reports. Returns one line per profile.
    @discardableResult
    public static func run(_ profiles: [Profile], env: HopperEnvironment) -> [String] {
        guard let claude = Claude.locate(env) else { return ["claude not found on PATH"] }
        let scratch = FileManager.default.temporaryDirectory
        return profiles.filter { !$0.isGateway }.map { p in
            let childEnv = LaunchPlan.childEnvironment(base: env.vars, profile: p, sessionID: "", env: env, userStatusCommand: nil)
            let a = OneShot.attempt(claude, args: args, env: childEnv, stdin: Data("reply ok".utf8), passThrough: false,
                                    stop: Terminator(), cwd: scratch)
            let now = FileIO.now()
            let failure = OneShot.classify(a, now: now)
            if let l = a.limits { try? LimitStore.write(l, profile: p.name, env.paths) }
            if case .limit = failure { OneShot.markFull(p, failure, attempt: a, paths: env.paths, now: now) }
            switch failure {
            case .login: return "\(p.name): not logged in"
            case .other where a.limits == nil: return "\(p.name): no usage in the reply (exit \(a.exit))"
            default: return "\(p.name): \(ProfileLimits.label(LimitStore.read(p.name, env.paths), now: now))"
            }
        }
    }
}
