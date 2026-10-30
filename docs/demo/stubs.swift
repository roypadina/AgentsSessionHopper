// Stand-ins for the two app types AppModel.swift / PopoverView.swift reach outside the engine, so the REAL views compile unchanged.
import SessionHopperCore

@MainActor final class Notifier { func update(_ s: HopperSnapshot) {} }   // Notifier.swift posts system notifications; the demo has none
@MainActor enum OnboardingWindow { static func show(model: AppModel) {} } // Onboarding.swift:8 (static func show), only reachable from "Set Up Profiles…" with no profiles
