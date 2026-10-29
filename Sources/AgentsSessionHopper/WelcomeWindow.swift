import ServiceManagement
import SessionHopperCore
import SwiftUI

/// First-launch welcome (MBX-18): why the app exists, how to use it, how to get back in without the icon (MBX-8)
/// and the login item (MBX-17). Shown once; again from Settings > About. The setup window stays on demand.
@MainActor
enum WelcomeWindow {
    static let shownKey = "didShowWelcome"
    private static var window: NSWindow?

    static func showIfNeeded(model: AppModel) {
        guard ProcessInfo.processInfo.environment["ASH_DEBUG_OPEN"] == nil,
              !UserDefaults.standard.bool(forKey: shownKey) else { return }
        UserDefaults.standard.set(true, forKey: shownKey)
        show(model: model)
    }

    static func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: WelcomeView(
                onSetUp: { window?.close(); OnboardingWindow.show(model: model) },
                onDone: { window?.close() })))
            w.title = "Welcome"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        if let window { AccessoryWindows.shared.show(window) }
    }
}

struct WelcomeView: View {
    let onSetUp: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: AboutView.icon).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to AgentsSessionHopper").font(.title2.bold())
                    Text("When one of your Claude accounts hits its usage limit, your work stops mid-task. AgentsSessionHopper keeps your own accounts side by side as profiles and, when you say so, continues the same conversation on another one.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            row("menubar.rectangle", "AgentsSessionHopper lives in the menu bar.",
                "The icon shows your fullest profile's usage. Click it for profiles, live sessions and any move waiting for you. Right-click for Settings.")
            row("arrow.triangle.swap", "Start Claude Code with sessionhopper.",
                "Run sessionhopper instead of claude, or let Setup add a shell alias. Near a limit you are asked whether to continue on another profile. Nothing moves until you confirm.")
            row("lock.shield", "Your logins stay yours.",
                "It never reads your Claude login or tokens and makes no network requests. Use it only with accounts that are yours.")
            row("questionmark.circle", "Icon missing?",
                "Open AgentsSessionHopper again from Applications to get Settings. A full menu bar can hide the icon.")
            LaunchAtLoginToggle()
            SupportBox()
            HStack {
                Button("Set Up Profiles…", action: onSetUp)
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Settings > General and the welcome window (MBX-17): user action only, status re-read on activation.
struct LaunchAtLoginToggle: View {
    @State private var status = SMAppService.mainApp.status

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open at Login", isOn: Binding(
                get: { status == .enabled },
                set: { on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    status = SMAppService.mainApp.status
                }))
            if status == .requiresApproval {
                Button("Allow in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            } else if status == .notFound {
                Text("Move AgentsSessionHopper to Applications to open it at login.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = SMAppService.mainApp.status  // the user may change it in System Settings
        }
    }
}

/// Quiet Ko-fi box (house style H1): the app's own next step stays the primary button, so this one is `.bordered`.
struct SupportBox: View {
    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free and open source").font(.headline)
                    Text("If AgentsSessionHopper saves you time, a coffee on Ko-fi keeps the next one coming.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Link("Support on Ko-fi ☕", destination: HopperInfo.koFi).buttonStyle(.bordered)
            }
            .padding(4)
        }
    }
}
