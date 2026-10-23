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
                    .help("Settings")
                    .accessibilityLabel("Settings")
            }

            section("Profiles") {
                if model.config.profiles.isEmpty {
                    Text("No profiles yet. In Terminal: sessionhopper profiles import")
                        .font(.callout).foregroundStyle(.secondary)
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
                    ForEach(model.snapshot.sessions) { SessionRow(model: model, session: $0) }
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

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
        HStack(spacing: 8) {
            Circle().fill(model.severity(profile.name).color).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(profile.name).frame(width: 80, alignment: .leading).lineLimit(1)
            Text("5h \(percentText(five))").monospacedDigit().frame(width: 62, alignment: .leading)
            Text("7d \(percentText(week))").monospacedDigit().frame(width: 62, alignment: .leading)
            Text(note(l, now: s.now)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if count > 0 {
                Text("\(count) session\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func note(_ l: ProfileLimits?, now: Double) -> String {
        guard let l else { return "no data yet" }
        guard let w = l.blocking(now: now) else { return "reset since last seen" }
        if model.severity(profile.name) != .ok, let r = w.window.resetsAt { return "resets \(clock(r))" }
        return relative(l.sampledAt, now: now)
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
        let head = s.reason == "limit" ? "\(s.from) hit its usage limit." : "\(s.from) is near its usage limit\(pct)."
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
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Move…") {
                ForEach(model.config.profiles.filter { $0.name != session.record.profile }) { p in
                    Button("\(p.name) (\(percentText(model.snapshot.percent(p.name))))") { model.confirmMove(session, to: p.name) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var status: String {
        var parts = [session.record.profile, session.busy ? "working" : "idle"]
        if session.held { parts.append("held") }
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
            Text(summary).lineLimit(1)
            Spacer()
        }
        .font(.callout)
    }

    var summary: String {
        let dir = event.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
        switch event.type {
        case "switch": return "\(dir)  \(event.from ?? "?") → \(event.to ?? "?")  (\(event.trigger ?? ""))"
        case "park": return "\(dir)  parked on \(event.from ?? "?")"
        case "limit": return "\(dir)  \(event.from ?? "?") hit its limit"
        case "suggest": return "\(dir)  suggested \(event.from ?? "?") → \(event.to ?? "–")"
        default: return event.type
        }
    }
}
