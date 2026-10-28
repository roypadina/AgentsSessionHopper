import Foundation
import SessionHopperCore
import UserNotifications

/// One notification per new suggestion, with "Move at turn end" / "Not now" / "Hold" actions.
/// Only in the packaged app: UNUserNotificationCenter needs a bundle.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "notificationsEnabled"
    static let category = "SUGGESTION"
    enum Action: String { case move = "MOVE", notNow = "NOT_NOW", hold = "HOLD" }

    private weak var model: AppModel?
    private var posted = Set<String>()
    /// Park events already in the log when the app started are not news.
    private var seenParks: Set<String>?
    private let center: UNUserNotificationCenter?

    init(model: AppModel) {
        self.model = model
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        super.init()
        guard let center else { return }
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.category,
            actions: [UNNotificationAction(identifier: Action.move.rawValue, title: "Move at turn end"),
                      UNNotificationAction(identifier: Action.notNow.rawValue, title: "Not now"),
                      UNNotificationAction(identifier: Action.hold.rawValue, title: "Hold")],
            intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// Called on every refresh; posts only what it has not posted before.
    func update(_ snapshot: HopperSnapshot) {
        let parks = snapshot.events.filter { $0.type == "park" }
        let fresh = seenParks.map { seen in parks.filter { !seen.contains($0.id) } } ?? []
        seenParks = (seenParks ?? []).union(parks.map(\.id))
        guard let center, enabled else { return }
        // One per park: the session waits for a reset or stopped, so nothing runs into paid usage.
        for e in fresh {
            let content = UNMutableNotificationContent()
            content.title = e.to == nil ? "Session stopped: no profile has room" : "Session waits for a usage reset"
            content.body = (e.cwd.map { model?.tilde($0) ?? $0 } ?? "") + ": "
                + (e.detail ?? "nothing runs into paid usage. Continue later: sessionhopper --resume \(e.session ?? "")")
            center.add(UNNotificationRequest(identifier: e.id, content: content, trigger: nil))
        }
        for s in snapshot.needsAttention {
            guard let sug = s.suggestion else { continue }
            let key = "\(s.record.session)|\(sug.from)|\(sug.reason)"
            guard posted.insert(key).inserted else { continue }
            let content = UNMutableNotificationContent()
            content.title = sug.reason == "login" ? "\(sug.from)'s Claude login expired" : sug.reason == "limit" ? "\(sug.from) hit its usage limit" : "\(sug.from) is near its usage limit"
            content.body = (sug.detail.map { "\($0). " } ?? "") + (sug.to.map { "Continue this conversation on \($0)? " } ?? "No other profile has room right now. ")
                + "(\(model?.tilde(s.record.cwd) ?? s.record.cwd))"
            content.categoryIdentifier = sug.to == nil ? "" : Self.category
            content.userInfo = ["session": s.record.session]
            center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard let session = response.notification.request.content.userInfo["session"] as? String else { return }
        await MainActor.run {
            guard let model, let s = model.snapshot.sessions.first(where: { $0.record.session == session }) else { return }
            switch Action(rawValue: action) {
            case .move: model.confirmMove(s)
            case .notNow: model.notNow(s)
            case .hold: model.hold(s)
            case nil: break
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}
