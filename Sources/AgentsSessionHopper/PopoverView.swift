import SessionHopperCore
import SwiftUI

/// The menu-bar window: profiles, what needs the user, live sessions, recent hand-offs.
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
            }

            section("Profiles") {
                if model.config.profiles.isEmpty {
                    Text("No profiles yet.").font(.callout).foregroundStyle(.secondary)
                    Button("Set Up Profiles…") { OnboardingWindow.show(model: model) }
                }
                ForEach(model.config.profiles) { ProfileRow(model: model, profile: $0) }
            }

            if !model.snapshot.needsAttention.isEmpty {
                section("Needs you") {
                    ForEach(model.snapshot.needsAttention) { SuggestionCard(model: model, session: $0) }
                }
            }

            if !model.snapshot.sessions.isEmpty {
                section("Sessions") {
                    // A bare ScrollView does not hug its content in this self-sizing panel, so only long lists get one.
                    if model.snapshot.sessions.count > 8 {
                        ScrollView { VStack(alignment: .leading, spacing: 6) { sessionRows } }.frame(height: 300)
                    } else {
                        sessionRows
                    }
                }
            }

            section("Recent hand-offs") {
                if model.recent.isEmpty {
                    Text("None yet.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.recent) { EventRow(event: $0) }
            }

            if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(width: 400)
    }

    private var sessionRows: some View {
        ForEach(model.snapshot.sessions) { SessionRow(model: model, session: $0) }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

struct ProfileRow: View {
    @ObservedObject var model: AppModel
    let profile: Profile

    var body: some View {
        let s = model.snapshot
        let l = s.limits[profile.name]
        let five = l?.fiveHour.flatMap { $0.isLive(now: s.now) ? $0.usedPercentage : nil }
        let week = l?.sevenDay.flatMap { $0.isLive(now: s.now) ? $0.usedPercentage : nil }
        let count = s.sessions(on: profile.name).count
        let severity = model.severity(profile.name)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: severity.symbol).foregroundStyle(severity.color).frame(width: 14)
                    .accessibilityHidden(true)
                Text(profile.name).frame(width: 80, alignment: .leading).lineLimit(1).help(profile.name)
                Text("5h \(percentText(five))").monospacedDigit().frame(width: 62, alignment: .leading)
                Text("7d \(percentText(week))").monospacedDigit().frame(width: 62, alignment: .leading)
                Spacer()
                if count > 0 {
                    Text("\(count) session\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                }
            }
            // Own line under the name: the reset time is the key fact of wait-for-reset and must not be cut.
            Text(note(l, now: s.now)).font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.name), 5-hour usage \(spoken(five)), weekly \(spoken(week)), \(severity.spoken)"
            + (count > 0 ? ", \(count) session\(count == 1 ? "" : "s")" : ""))
        .accessibilityValue(note(l, now: s.now))
    }

    private func spoken(_ v: Double?) -> String { v.map { "\(Int($0.rounded())) percent" } ?? "unknown" }

    private func note(_ l: ProfileLimits?, now: Double) -> String { l?.note(now: now) ?? "no data yet" }
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

struct SessionRow: View {
    @ObservedObject var model: AppModel
    let session: LiveSession

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.tilde(session.record.cwd)).lineLimit(1).truncationMode(.head)
                    .help(model.tilde(session.record.cwd))
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Menu("Move…") {
                ForEach(model.config.profiles.filter { $0.name != session.record.profile }) { p in
                    Button("\(p.name) (\(percentText(model.snapshot.percent(p.name))))") { model.confirmMove(session, to: p.name) }
                }
                Divider()
                // "Hold every session" holds it too and only Settings turns that off, so releasing one here would do nothing.
                Button(session.held ? "Release Hold" : "Hold") { model.hold(session, on: !session.held) }
                    .disabled(session.held && model.holdAll)
                    .help(session.held && model.holdAll ? "Hold every session is on. Turn it off in Settings > Hand-off." : "")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Move \(model.tilde(session.record.cwd))")
        }
    }

    private var status: String {
        var parts = [session.record.profile, session.busy ? "working" : "idle"]
        if session.held { parts.append("held") }
        if let t = session.waitingUntil { parts.append("parked, waits for a reset until \(ProfileLimits.clock(t))") }
        if let p = session.pending {
            parts.append(p.to == PendingMove.park ? "parks at turn end" : "moves to \(p.to == PendingMove.anywhere ? "next" : p.to) at turn end")
        }
        return parts.joined(separator: " · ")
    }
}

struct EventRow: View {
    let event: HopperEvent

    var body: some View {
        HStack(spacing: 8) {
            Text(eventTime(event.ts)).monospacedDigit().foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(summary).lineLimit(1).help(summary)
            Spacer()
        }
        .font(.callout)
    }

    var summary: String {
        let dir = event.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
        switch event.type {
        case "switch": return "\(dir)  \(event.from ?? "?") → \(event.to ?? "?")" + (event.trigger.map { "  (\($0))" } ?? "")
        case "park": return "\(dir)  parked on \(event.from ?? "?")" + (event.to.map { ", waits for \($0)" } ?? "")
        case "limit": return "\(dir)  \(event.from ?? "?") hit its limit"
        case "suggest": return "\(dir)  suggested \(event.from ?? "?") → \(event.to ?? "–")"
        default: return event.type
        }
    }
}
