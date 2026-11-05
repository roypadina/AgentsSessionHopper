import SessionHopperCore
import SwiftUI

/// The menu-bar window: what needs the user, then one row per profile. Sessions sit in a menu on their profile's
/// row and the hand-off history in Settings > Log, so the window stays the same short size.
struct PopoverView: View {
    @ObservedObject var model: AppModel
    var openSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AgentsSessionHopper").font(.headline)
                Spacer()
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(",")
                    .help("Settings")
                    .accessibilityLabel("Settings")
                MoreMenu()
            }

            ForEach(model.snapshot.needsAttention) { SuggestionCard(model: model, session: $0) }

            VStack(alignment: .leading, spacing: 10) {
                if model.config.profiles.isEmpty {
                    Text("No profiles yet.").font(.callout).foregroundStyle(.secondary)
                    Button("Set Up Profiles…") { OnboardingWindow.show(model: model) }
                }
                ForEach(model.config.profiles) { ProfileRow(model: model, profile: $0) }
            }

            if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}

/// The right-click menu's items, for people who never right-click (MBX-12). The gear next to it is Settings.
struct MoreMenu: View {
    var body: some View {
        Menu {
            Button("Show Hand-off Log") { StatusMenu.shared.switchLog() }
            Divider()
            Button("Request a feature") { NSWorkspace.shared.open(StatusMenu.requestFeature) }
            Button("Contribute") { NSWorkspace.shared.open(StatusMenu.contribute) }
            Button("About AgentsSessionHopper") { AboutWindow.show() }
            Button("Support on Ko-fi ☕") { NSWorkspace.shared.open(HopperInfo.koFi) }
            Divider()
            Button("Quit AgentsSessionHopper") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }
}

/// One profile: state, the fullest window, and the one fact that matters next (when it switches at this pace,
/// when it is free again, or that it is ready). Both windows and the reset are in the tooltip.
struct ProfileRow: View {
    @ObservedObject var model: AppModel
    let profile: Profile

    var body: some View {
        let s = model.snapshot
        let l = s.limits[profile.name]
        let w = l?.blocking(now: s.now)
        let five = l?.fiveHour.flatMap { $0.isLive(now: s.now) ? $0.usedPercentage : nil }
        let week = l?.sevenDay.flatMap { $0.isLive(now: s.now) ? $0.usedPercentage : nil }
        let sessions = s.sessions(on: profile.name)
        let severity = model.severity(profile.name)
        let next = outlook(l, active: !sessions.isEmpty, now: s.now)
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: severity.symbol).foregroundStyle(severity.color).frame(width: 14)
                    Text(profile.name).lineLimit(1).frame(width: 76, alignment: .leading)
                    Gauge(value: min(w?.window.usedPercentage ?? 0, 100), in: 0...100) { EmptyView() }
                        .gaugeStyle(.linearCapacity)
                        .tint(severity.color)
                        .opacity(w == nil ? 0 : 1)
                    Text(w.map { "\($0.name) \(percentText($0.window.usedPercentage))" } ?? "–")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                }
                Text(next).font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
            }
            .help([five.map { "5h \(percentText($0))" }, week.map { "7d \(percentText($0))" }, l?.note(now: s.now)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(profile.name), \(severity.spoken), 5-hour usage \(spoken(five)), weekly \(spoken(week))")
            .accessibilityValue(next)

            SessionsMenu(model: model, sessions: sessions)
                .frame(width: 84, alignment: .trailing)
                .opacity(sessions.isEmpty ? 0 : 1)
                .disabled(sessions.isEmpty)
                .accessibilityHidden(sessions.isEmpty)
        }
    }

    private func spoken(_ v: Double?) -> String { v.map { "\(Int($0.rounded())) percent" } ?? "unknown" }

    /// `active`: the profile has live sessions, so it is spending and a pace means something.
    private func outlook(_ l: ProfileLimits?, active: Bool, now: Double) -> String {
        if profile.isGateway { return "Pay per use" }
        guard let l else { return "No usage seen yet" }
        let c = model.config
        var text = "Ready"
        if let pct = l.percent(now: now) {
            let resets = l.blocking(now: now)?.window.resetsAt.map(ProfileLimits.clock)
            if pct >= c.hardThreshold {
                text = l.freeAt(under: c.hardThreshold, now: now).map { "Full · free again \(ProfileLimits.clock($0))" } ?? "Full"
            } else if active,
                      // Past the suggest threshold the session already stayed (held, asked, or no room), so the next event is full.
                      case let to = pct < c.suggestThreshold ? Policy(config: c, limits: model.snapshot.limits, now: now).pick(c.profiles, excluding: profile.name) : nil,
                      // No profile to switch to: it runs on until the hard threshold.
                      let at = l.reaches(to == nil ? c.hardThreshold : c.suggestThreshold, now: now) {
                text = "At this pace: " + (to.map { "switch to \($0.name)" } ?? "full")
                    + (at <= now ? " soon" : " ≈ \(ProfileLimits.clock(at))")
            } else if active {
                text = resets.map { "Lasts until the reset at \($0)" } ?? "Has room"
            } else if pct >= c.suggestThreshold {
                text = "Near its limit" + (resets.map { " · resets \($0)" } ?? "")
            }
        }
        if now - l.sampledAt >= ProfileLimits.staleAfter { text += " · seen \(ProfileLimits.age(now - l.sampledAt)) ago" }
        return text
    }
}

/// A profile's live sessions, each a submenu with its moves and hold.
struct SessionsMenu: View {
    @ObservedObject var model: AppModel
    let sessions: [LiveSession]

    var body: some View {
        Menu("\(sessions.count) session\(sessions.count == 1 ? "" : "s")") {
            ForEach(sessions) { session in
                Menu(title(session)) {
                    ForEach(model.config.profiles.filter { $0.name != session.record.profile }) { p in
                        Button("Move to \(p.name) (\(percentText(model.snapshot.percent(p.name))))") { model.confirmMove(session, to: p.name) }
                    }
                    if session.pending != nil { Button("Cancel Move") { model.cancelMove(session) } }
                    Divider()
                    // "Hold every session" holds it too and only Settings turns that off, so releasing one here would do nothing.
                    Button(session.held ? "Release Hold" : "Hold") { model.hold(session, on: !session.held) }
                        .disabled(session.held && model.holdAll)
                        .help(session.held && model.holdAll ? "Hold every session is on. Turn it off in Settings > Hand-off." : "")
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// "~/Code/app · working · 1a2b3c4d": the id tells apart sessions in one folder and matches `status`.
    private func title(_ session: LiveSession) -> String {
        var parts = [model.tilde(session.record.cwd), session.busy ? "working" : "idle"]
        if session.held { parts.append("held") }
        if let t = session.waitingUntil { parts.append("parked, waits for a reset until \(ProfileLimits.clock(t))") }
        if let p = session.pending {
            parts.append(p.to == PendingMove.park ? "parks at turn end" : "moves to \(p.to == PendingMove.anywhere ? "next" : p.to) at turn end")
        }
        parts.append(String(session.id.prefix(8)))
        return parts.joined(separator: " · ")
    }
}

/// The confirm prompt: nothing moves until the user says so (unless they opted in to moving without asking).
struct SuggestionCard: View {
    @ObservedObject var model: AppModel
    let session: LiveSession

    var body: some View {
        let sug = session.suggestion!
        VStack(alignment: .leading, spacing: 8) {
            Text(headline(sug)).fixedSize(horizontal: false, vertical: true)
            Text("\(model.tilde(session.record.cwd)) · \(session.busy ? "working" : "idle")")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(sug.to.map { "Move to \($0) at turn end" } ?? "Move at turn end") { model.confirmMove(session) }
                    .buttonStyle(.borderedProminent)
                    .disabled(sug.to == nil)
                Button("Not now") { model.notNow(session) }
                Button("Hold") { model.hold(session) }
                    .help("Keep this session on its profile: no park, no automatic move.")
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private func headline(_ s: Suggestion) -> String {
        let pct = s.percent.map { " (\(Int($0.rounded()))%)" } ?? ""
        let head = s.reason == "login" ? "\(s.from)'s Claude login expired." : s.reason == "limit" ? "\(s.from) hit its usage limit\(s.detail.map { " (\($0))" } ?? "")." : "\(s.from) is near its usage limit\(pct)."
        return head + (s.to.map { " Continue this conversation on \($0)?" } ?? " No other profile has room right now.")
    }
}
