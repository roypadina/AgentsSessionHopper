// Stand-ins for the app types AppModel.swift / PopoverView.swift reach outside the engine, so the REAL views compile unchanged.
import Foundation
import SessionHopperCore

@MainActor final class Notifier { func update(_ s: HopperSnapshot) {} }   // Notifier.swift posts system notifications; the demo has none
@MainActor enum OnboardingWindow { static func show(model: AppModel) {} } // Onboarding.swift:8 (static func show), only reachable from "Set Up Profiles…" with no profiles
@MainActor enum AboutWindow { static func show() {} }                     // AboutView.swift, opened from the ⋯ menu; the demo never opens it
@MainActor final class StatusMenu {                                         // StatusMenu.swift: the ⋯ menu's log item and links
    static let shared = StatusMenu()
    static let requestFeature = URL(string: "https://example.com")!, contribute = URL(string: "https://example.com")!
    func switchLog() {}
}
