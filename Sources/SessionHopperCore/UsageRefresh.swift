import Foundation

/// Fresh usage for profiles no session has reported on lately. A sample only comes from a session running on
/// that profile, so an idle profile kept its last numbers for days (and a limit reset on the account's page went
/// unseen). One tiny `claude -p` on the cheapest model prints a `rate_limit_event` with both windows.
public enum UsageRefresh {
    /// Samples older than this are refreshed by the app (and `refresh --stale`).
    public static let maxAge: Double = 6 * 3600
    /// A probe that has not finished by then is ended.
    static let timeout: Double = 60

    /// Claude profiles (gateways have no plan windows) with no sample, or one older than `maxAge`, that were not
    /// already tried within `maxAge` (`tried`: profile → last attempt), so a probe that stores nothing (logged out,
    /// offline, no plan) is not repeated every few minutes.
    public static func due(_ config: HopperConfig, limits: [String: ProfileLimits], tried: [String: Double] = [:], now: Double) -> [Profile] {
        config.profiles.filter { p in
            !p.isGateway && (limits[p.name].map { now - $0.sampledAt >= maxAge } ?? true) && (tried[p.name].map { now - $0 >= maxAge } ?? true)
        }
    }

    /// The probe: no tools, no MCP, no settings (hooks, plugins), no saved transcript, run in a scratch folder.
    static let args = ["-p", "--model", "haiku", "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                       "--no-session-persistence", "--max-turns", "1", "--output-format", "stream-json", "--verbose"]

    /// Refreshes `profiles` one by one and stores what each run reports: one line per profile, `ok` false when
    /// any probe failed. `stop`: the CLI's Ctrl-C handler; the app passes one without signal handling.
    @discardableResult
    public static func run(_ profiles: [Profile], env: HopperEnvironment, stop: Terminator) -> (lines: [String], ok: Bool) {
        guard let claude = Claude.locate(env) else { return (["claude not found on PATH"], false) }
        let scratch = FileManager.default.temporaryDirectory
        var lines: [String] = [], ok = true
        for p in profiles {
            if stop.requested { break }
            if p.isGateway { lines.append("\(p.name): skipped (pay-per-use profile, no plan windows)"); continue }
            let childEnv = LaunchPlan.childEnvironment(base: env.vars, profile: p, sessionID: "", env: env, userStatusCommand: nil)
            let watchdog = DispatchWorkItem { if let c = stop.child, c.isRunning { c.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let a = OneShot.attempt(claude, args: args, env: childEnv, stdin: Data("reply ok".utf8), passThrough: false,
                                    stop: stop, cwd: scratch)
            watchdog.cancel()
            let now = FileIO.now()
            if let l = a.limits { try? LimitStore.write(l, profile: p.name, env.paths) }
            // Only Claude Code's own "rejected" event marks a profile full: failure text alone could stamp an old sample as new.
            if a.rejected != nil { OneShot.markFull(p, OneShot.classify(a, now: now), attempt: a, paths: env.paths, now: now) }
            if a.limits == nil, a.rejected == nil {
                ok = false
                lines.append("\(p.name): " + (OneShot.classify(a, now: now) == .login ? "not logged in" : "no usage in the reply (exit \(a.exit))"))
            } else {
                lines.append("\(p.name): \(ProfileLimits.label(LimitStore.read(p.name, env.paths), now: now))")
            }
        }
        return (lines, ok)
    }
}
