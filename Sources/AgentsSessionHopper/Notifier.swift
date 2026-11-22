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
    /// Alerts already in the log when the app started are not news.
    private var seenAlerts: Set<String>?
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
        // Alerts the engine decided on (`Alerts`: per profile and kind, one per event however many sessions moved).
        let alerts = model.map { Alerts.read($0.env.paths, last: 50) } ?? []
        let fresh = seenAlerts.map { seen in alerts.filter { !seen.contains($0.id) } } ?? []
        seenAlerts = (seenAlerts ?? []).union(alerts.map(\.id))
        guard let center else { return }
        for r in fresh where r.mac {
            let content = UNMutableNotificationContent()
            content.title = r.title
            content.body = r.body
            center.add(UNNotificationRequest(identifier: r.id, content: content, trigger: nil))
        }
        guard enabled else { return }
        for s in snapshot.needsAttention {
            guard let sug = s.suggestion else { continue }
            let key = "\(s.record.session)|\(sug.from)|\(sug.reason)"
            guard posted.insert(key).inserted else { continue }
            let content = UNMutableNotificationContent()
            let from = model?.config.display(sug.from) ?? sug.from
            content.title = sug.reason == "login" ? "\(from)'s Claude login expired" : sug.reason == "limit" ? "\(from) hit its usage limit" : "\(from) is near its usage limit"
            content.body = (sug.detail.map { "\($0). " } ?? "") + (sug.to.map { "Continue this conversation on \(model?.config.display($0) ?? $0)? " } ?? "No other profile has room right now. ")
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
