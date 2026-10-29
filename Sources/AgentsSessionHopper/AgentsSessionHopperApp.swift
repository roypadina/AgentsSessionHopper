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
        .commands {  // App menu while a window is open (policy .regular)
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { Self.openSettings() }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .appInfo) {
                Button("About AgentsSessionHopper") { AboutWindow.show() }
            }
        }
    }

    @MainActor static func makeModel() -> AppModel {
        let model = AppModel(env: .current(selfPath: cliPath))
        SettingsWindow.model = model
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

    @MainActor static func openSettings() { SettingsWindow.show() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        MainActor.assumeIsolated { StatusMenu.shared.install() }
        #if DEBUG
        // Test hook: ASH_DEBUG_OPEN="Settings…" (any status-menu title) fires that item exactly as a click would.
        if let title = ProcessInfo.processInfo.environment["ASH_DEBUG_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    guard let i = StatusMenu.shared.menu().items.first(where: { $0.title == title }), let a = i.action else { return }
                    NSApp.sendAction(a, to: i.target, from: i)
                }
            }
        }
        #endif
    }

    /// Opening AgentsSessionHopper again (Finder, Raycast) shows Settings: the way in when the icon is hidden (MBX-8).
    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindow.show() }
        return true
    }
}
