import SessionHopperCore
import SwiftUI

@main
struct AgentsSessionHopperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel(env: .current(selfPath: AgentsSessionHopperApp.cliPath))

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model, openSettings: Self.openSettings)
            Divider()
            HStack {
                Button("About AgentsSessionHopper") { AboutWindow.show() }
                Button("Support on Ko-fi ☕") { NSWorkspace.shared.open(HopperInfo.koFi) }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// Icon reflects state: plain, a dot when something needs you, a warning past the park threshold.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let s = model.snapshot
        let symbol = !s.needsAttention.isEmpty ? "arrow.triangle.2.circlepath.circle.fill"
            : (s.worstLivePercent ?? 0) >= model.config.hardThreshold ? "exclamationmark.arrow.triangle.2.circlepath"
            : "arrow.triangle.swap"
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if let p = s.worstLivePercent { Text(percentText(p)).monospacedDigit() }
        }
        .accessibilityLabel(s.needsAttention.isEmpty ? "AgentsSessionHopper" : "AgentsSessionHopper: a session needs you")
    }
}

extension AgentsSessionHopperApp {
    /// The CLI ships next to the app executable, in Contents/Helpers.
    static var cliPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sessionhopper").path
    }

    @MainActor static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
