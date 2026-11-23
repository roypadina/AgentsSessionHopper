import AppKit
import SessionHopperCore
import SwiftUI

/// Reads the engine's state directory every couple of seconds and writes the user's choices back
/// through the same files the CLI uses. No network, no credentials: only that directory, plus a tiny `claude -p`
/// per profile whose usage is over 6 hours old (`UsageRefresh`) or on Refresh.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: HopperSnapshot
    @Published var lastError: String?
    let env: HopperEnvironment
    private var timer: Timer?
    private var staleTimer: Timer?
    @Published private(set) var refreshing = false
    /// Profile → last automatic refresh attempt, so one that never reports (logged out, offline) is not retried every 10 min.
    private var tried: [String: Double] = [:]

    init(env: HopperEnvironment, autoRefresh: Bool = true) {
        self.env = env
        snapshot = HopperSnapshot.load(env.paths, home: env.home, events: 200)
        guard autoRefresh else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refreshUsage(onlyStale: true)
        staleTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshUsage(onlyStale: true) }
        }
    }

    /// Fresh usage from Claude itself (`UsageRefresh`): every Claude profile, or only those with no sample in 6 h.
    func refreshUsage(onlyStale: Bool = false) {
        guard !refreshing else { return }
        let config = config, env = env
        let now = Date().timeIntervalSince1970
        let profiles = onlyStale ? UsageRefresh.due(config, limits: snapshot.limits, tried: tried, now: now) : config.profiles
        guard !profiles.isEmpty else { return }
        for p in profiles { tried[p.name] = now }
        refreshing = true
        Task.detached {
            UsageRefresh.run(profiles, env: env, stop: Terminator(handleSignals: false))
            await MainActor.run { self.refreshing = false; self.refresh() }
        }
    }

    /// Set by the app (not in tests); told about every new snapshot.
    var notifier: Notifier?

    func refresh() {
        let s = HopperSnapshot.load(env.paths, home: env.home, events: 200)
        if s != snapshot { snapshot = s }
        notifier?.update(s)
    }

    var config: HopperConfig { snapshot.config }

    // MARK: Actions (same file protocol as the CLI)

    func confirmMove(_ s: LiveSession, to: String? = nil) {
        act { _ = try Control.requestMove(session: s.record.session, to: to ?? s.suggestion?.to, now: false, source: "menu", env: env) }
    }

    /// Every live session not already on `to` moves there at its turn end (like Move on each one). Held sessions too:
    /// the user asked for it by name.
    func moveAll(to: String) {
        act {
            for s in snapshot.sessions where s.record.profile != to {
                _ = try Control.requestMove(session: s.record.session, to: to, now: false, source: "menu", env: env)
            }
        }
    }

    /// Every live session on `from` moves to `to` at its turn end.
    func moveAll(from: String, to: String) {
        act {
            for s in snapshot.sessions(on: from) {
                _ = try Control.requestMove(session: s.record.session, to: to, now: false, source: "menu", env: env)
            }
        }
    }

    /// `spec`: as `Profile.pauseEnd` (`30m`, `forever`, `5h-reset`, …); nil = in use again.
    func pause(_ name: String, _ spec: String?) {
        let until = spec.flatMap { Profile.pauseEnd($0, limits: snapshot.limits[name], now: Date().timeIntervalSince1970) }
        if spec != nil, until == nil { lastError = "\(config.display(name)): no reset time known yet; refresh its usage first"; return }
        update { c in if let i = c.profiles.firstIndex(where: { $0.name == name }) { c.profiles[i].pausedUntil = until } }
    }

    func cancelMove(_ s: LiveSession) { act { _ = try Control.cancelMove(session: s.record.session, env: env) } }

    func notNow(_ s: LiveSession) { Control.dismiss(session: s.record.session, env: env); refresh() }

    func hold(_ s: LiveSession, on: Bool = true) { act { try Control.setHold(session: s.record.session, on: on, env: env) } }

    func setHoldAll(_ on: Bool) { act { try Control.setHold(session: nil, on: on, env: env) } }
    var holdAll: Bool { FileManager.default.fileExists(atPath: env.paths.holdAll.path) }

    func update(_ change: (inout HopperConfig) -> Void) {
        var c = config
        change(&c)
        act { try c.save(env.paths) }
    }

    func moveProfile(_ name: String, by delta: Int) {
        update { c in
            guard let i = c.profiles.firstIndex(where: { $0.name == name }) else { return }
            let j = min(max(i + delta, 0), c.profiles.count - 1)
            c.profiles.swapAt(i, j)
        }
    }

    /// Drag-to-reorder in Settings; the list order is the fallback order (same as `profiles order`).
    func moveProfiles(from source: IndexSet, to destination: Int) {
        update { $0.profiles.move(fromOffsets: source, toOffset: destination) }
    }

    // MARK: Profiles and logins

    /// Logged-in state per profile from `claude auth status` (nil = not checked or claude not found).
    @Published private(set) var loggedIn: [String: Bool] = [:]
    @Published private(set) var checkingLogins = false

    /// Profiles on disk that are not in the list yet.
    var discovered: [Profile] {
        let known = Set(config.profiles.map(\.dir))
        return Profiles.discover(home: env.home).filter { !known.contains($0.dir) }
    }

    func importDiscovered() { update { $0.profiles += discovered } }

    /// Creates the folder (history linked to the first profile) and adds it. Login is a separate, user-run step.
    @discardableResult
    func addProfile(name: String, shareSetup: Bool) -> Profile? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard config.profile(named: name) == nil else { lastError = "profile '\(name)' exists"; return nil }
        let dir = env.home.appendingPathComponent(".claude-\(name)")
        do {
            _ = try Profiles.create(name: name, dir: dir, base: config.profiles.first, home: env.home, shareSetup: shareSetup)
        } catch {
            lastError = "\(error)"
            return nil
        }
        let p = Profile(name: name, dir: dir.path, exportConfigDir: true)
        update { $0.profiles.append(p) }
        return p
    }

    /// An API-key profile (OpenRouter, Anthropic API or another gateway) in the first Claude profile's folder
    /// (history shared); the key goes to the Keychain.
    @discardableResult
    func addGateway(name: String, kind: String = Gateway.openRouter, baseURL: String? = nil, key: String, models: [String: String], resets: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard Profiles.isValidName(name) else { lastError = "profile names use letters, digits, - and _"; return false }
        guard config.profile(named: name) == nil else { lastError = "profile '\(name)' exists"; return false }
        guard let base = config.profiles.first(where: { !$0.isGateway }) else { lastError = "add a Claude profile first"; return false }
        let url = baseURL?.trimmingCharacters(in: .whitespaces)
        if kind == Gateway.custom, !(url.map(Gateway.validURL) ?? false) { lastError = "enter the gateway's http(s) URL"; return false }
        let p = Profile(name: name, dir: base.dir, exportConfigDir: base.exportConfigDir, kind: kind,
                        models: models.isEmpty ? nil : models, baseURL: kind == Gateway.custom ? url : nil, resets: resets == "daily" ? nil : resets)
        do { try Gateway.storeKey(key, for: p, env: env) } catch { lastError = "\(error)"; return false }
        lastError = nil
        update { $0.profiles.append(p) }
        guard lastError == nil else { return false }
        checkLogins()
        return true
    }

    /// Off the list only: the folder, its login and any stored key stay.
    func removeProfile(_ name: String) { update { $0.profiles.removeAll { $0.name == name } } }

    /// nil = the default for its kind (Claude 1, API keys 10).
    func setPriority(_ name: String, _ value: Int?) {
        update { c in
            guard let i = c.profiles.firstIndex(where: { $0.name == name }) else { return }
            c.profiles[i].priority = value
        }
    }

    /// Empty = clear. Display only; the profile's name is untouched. false = clashes with another profile.
    @discardableResult func setLabel(_ name: String, _ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.labelClashes(t, for: name) { return false }
        update { c in
            guard let i = c.profiles.firstIndex(where: { $0.name == name }) else { return }
            c.profiles[i].label = t.isEmpty ? nil : t
        }
        return true
    }

    func priority(_ p: Profile) -> Int { Policy(config: config, limits: [:], now: 0).priority(p) }

    func checkLogins() {
        guard !checkingLogins else { return }
        checkingLogins = true
        let env = env, profiles = config.profiles
        Task.detached {
            var out: [String: Bool] = [:]
            for p in profiles { if let v = Claude.isLoggedIn(p, env: env) { out[p.name] = v } }
            await MainActor.run {
                self.loggedIn = out
                self.checkingLogins = false
            }
        }
    }

    func loginCommand(_ p: Profile) -> String { Profiles.loginCommand(for: p, tilde: env.tilde) }

    func copyLoginCommand(_ p: Profile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(loginCommand(p), forType: .string)
    }

    /// Opens Terminal on a script that runs Claude Code's own `claude auth login` for this profile.
    func openLoginInTerminal(_ p: Profile) {
        act { NSWorkspace.shared.open(try Claude.loginScript(p, env: env)) }
    }

    func revealLog() { NSWorkspace.shared.activateFileViewerSelecting([env.paths.events]) }

    // MARK: Setup (each step shows what it does; nothing runs until clicked)

    /// What the last setup step did, shown under it.
    @Published var setupLog: [String] = []
    @Published private(set) var pluginState: [String: Bool] = [:]
    @Published private(set) var doctor: [Doctor.Check] = []
    @Published private(set) var busy = false

    var cliPath: String { URL(fileURLWithPath: env.selfPath).resolvingSymlinksInPath().path }
    var shellKind: Setup.ShellKind { Setup.shellKind(env.vars) }
    var shellFile: String { tilde(Setup.rcFile(shellKind, home: env.home, vars: env.vars).path) }
    var aliasLine: String { Setup.aliasLine(shellKind, cli: cliPath) }
    var shellInstalled: Bool { Setup.shellInstalled(shellKind, home: env.home, vars: env.vars) }
    var shimLinked: Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: Setup.shimLink(home: env.home).path)) == cliPath }

    func share(_ p: Profile, dryRun: Bool) {
        guard let base = config.profiles.first else { return }
        do { setupLog = (dryRun ? ["\(p.displayName), would do:"] : ["\(p.displayName):"]) + (try Setup.share(p, base: base, dryRun: dryRun)) }
        catch { setupLog = ["\(error)"] }
    }

    func setShell(_ on: Bool) {
        do { setupLog = [on ? try Setup.installShell(shellKind, cli: cliPath, home: env.home, vars: env.vars)
                            : try Setup.removeShell(shellKind, home: env.home, vars: env.vars)] }
        catch { setupLog = ["\(error)"] }
        objectWillChange.send()
    }

    func linkShim() {
        do { setupLog = [try Setup.linkShim(cli: cliPath, home: env.home)] } catch { setupLog = ["\(error)"] }
        objectWillChange.send()
    }

    /// `claude plugin …` per profile takes seconds each: off the main thread.
    func checkPlugins(install: Bool = false) {
        guard !busy else { return }
        busy = true
        let env = env, profiles = config.profiles
        Task.detached {
            var state: [String: Bool] = [:], log: [String] = []
            for p in profiles {
                if install, Setup.pluginInstalled(p, env: env) != true {
                    do { log.append(try Setup.installPlugin(p, env: env)) } catch { log.append("\(error)") }
                }
                if let v = Setup.pluginInstalled(p, env: env) { state[p.name] = v }
            }
            await MainActor.run {
                self.pluginState = state
                if install { self.setupLog = log.isEmpty ? ["The skill is in every profile."] : log }
                self.busy = false
            }
        }
    }

    func runDoctor() {
        guard !busy else { return }
        busy = true
        let env = env
        Task.detached {
            let checks = Doctor.run(env: env)
            await MainActor.run { self.doctor = checks; self.busy = false }
        }
    }

    private func act(_ f: () throws -> Void) {
        do {
            try f()
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        refresh()
    }

    // MARK: Presentation helpers

    enum Severity { case unknown, ok, near, full, paused }

    func severity(_ profile: String) -> Severity {
        if config.profile(named: profile)?.isPaused(now: snapshot.now) == true { return .paused }
        guard let p = snapshot.percent(profile) else { return .unknown }
        return p >= config.hard(profile) ? .full : p >= config.suggest(profile) ? .near : .ok
    }

    func tilde(_ path: String) -> String { env.tilde(path) }
}

extension AppModel.Severity {
    /// Shape plus color, so the state never rests on color alone (CLR-4).
    var symbol: String {
        switch self {
        case .unknown: "circle.dashed"
        case .ok: "checkmark.circle.fill"
        case .near: "exclamationmark.triangle.fill"
        case .full: "xmark.octagon.fill"
        case .paused: "pause.circle.fill"
        }
    }

    var spoken: String {
        switch self {
        case .unknown: "no usage data yet"
        case .ok: "within its limits"
        case .near: "near its limit"
        case .full: "at its limit"
        case .paused: "paused"
        }
    }

    var color: Color {
        switch self {
        case .unknown: .secondary
        case .ok: .green
        case .near: .orange
        case .full: .red
        case .paused: .secondary
        }
    }
}

func percentText(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "–" }

/// "2026-10-23T14:02:11+03:00" → "14:02" (today) or "Oct 23 14:02".
func eventTime(_ iso: String) -> String {
    guard let d = ISO8601DateFormatter().date(from: iso) else { return iso }
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "MMM d HH:mm"
    return f.string(from: d)
}
