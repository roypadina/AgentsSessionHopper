import AppKit
import SessionHopperCore
import SwiftUI

/// Reads the engine's state directory every couple of seconds and writes the user's choices back
/// through the same files the CLI uses. No network, no credentials: only that directory.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: HopperSnapshot
    @Published var lastError: String?
    let env: HopperEnvironment
    private var timer: Timer?

    init(env: HopperEnvironment, autoRefresh: Bool = true) {
        self.env = env
        snapshot = HopperSnapshot.load(env.paths, events: 200)
        guard autoRefresh else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Set by the app (not in tests); told about every new snapshot.
    var notifier: Notifier?

    func refresh() {
        let s = HopperSnapshot.load(env.paths, events: 200)
        if s != snapshot { snapshot = s }
        notifier?.update(s)
    }

    var config: HopperConfig { snapshot.config }
    var recent: [HopperEvent] { Array(snapshot.events.suffix(5).reversed()) }

    // MARK: Actions (same file protocol as the CLI)

    func confirmMove(_ s: LiveSession, to: String? = nil) {
        act { _ = try Control.requestMove(session: s.record.session, to: to ?? s.suggestion?.to, now: false, source: "menu", env: env) }
    }

    func notNow(_ s: LiveSession) { Control.dismiss(session: s.record.session, env: env); refresh() }

    func hold(_ s: LiveSession) { act { try Control.setHold(session: s.record.session, on: true, env: env) } }

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

    enum Severity { case unknown, ok, near, full }

    func severity(_ profile: String) -> Severity {
        guard let p = snapshot.percent(profile) else { return .unknown }
        return p >= config.hardThreshold ? .full : p >= config.suggestThreshold ? .near : .ok
    }

    func tilde(_ path: String) -> String { env.tilde(path) }
}

extension AppModel.Severity {
    var color: Color {
        switch self {
        case .unknown: .secondary
        case .ok: .green
        case .near: .orange
        case .full: .red
        }
    }
}

func percentText(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "–" }

func relative(_ epoch: Double, now: Double) -> String {
    let m = Int((now - epoch) / 60)
    return m < 1 ? "just now" : m < 90 ? "\(m) min ago" : m < 48 * 60 ? "\(m / 60) h ago" : "\(m / 1440) d ago"
}

func clock(_ epoch: Double) -> String {
    let d = Date(timeIntervalSince1970: epoch)
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE HH:mm"
    return f.string(from: d)
}

/// "2026-10-23T14:02:11+03:00" → "14:02" (today) or "Oct 23 14:02".
func eventTime(_ iso: String) -> String {
    guard let d = ISO8601DateFormatter().date(from: iso) else { return iso }
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "MMM d HH:mm"
    return f.string(from: d)
}
