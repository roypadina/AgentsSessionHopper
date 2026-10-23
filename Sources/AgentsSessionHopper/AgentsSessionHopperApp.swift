import SessionHopperCore
import SwiftUI

@main
struct AgentsSessionHopperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AgentsSessionHopperApp.makeModel()

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

    @MainActor static func makeModel() -> AppModel {
        let model = AppModel(env: .current(selfPath: cliPath))
        EventLog.prune(model.env.paths, days: 90)
        model.notifier = Notifier(model: model)
        DispatchQueue.main.async {
            OnboardingWindow.showIfNeeded(model: model)
            model.checkLogins()
        }
        return model
    }
}

/// Template glyph; a badge when a session needs you, a warning past the park threshold.
struct MenuBarLabel: View {
    static let showPercentKey = "showPercentInMenuBar"
    @ObservedObject var model: AppModel
    @AppStorage(showPercentKey) private var showPercent = true

    var body: some View {
        let s = model.snapshot
        let full = (s.worstLivePercent ?? 0) >= model.config.hardThreshold
        HStack(spacing: 3) {
            if !s.needsAttention.isEmpty {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
            } else if full {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            } else {
                Image(nsImage: Self.glyph)
            }
            if showPercent, let p = s.worstLivePercent { Text(percentText(p)).monospacedDigit() }
        }
        .accessibilityLabel(s.needsAttention.isEmpty ? "AgentsSessionHopper" : "AgentsSessionHopper: a session needs you")
    }

    /// Bundled by Scripts/package_app.sh; `swift run` has no bundle resources, so it falls back to an SF Symbol.
    static let glyph: NSImage = {
        let image = NSImage(named: "menubar")
            ?? NSImage(systemSymbolName: "arrow.triangle.swap", accessibilityDescription: nil)
            ?? NSImage()
        image.isTemplate = true
        return image
    }()
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
