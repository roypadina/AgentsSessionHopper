import SessionHopperCore
import SwiftUI

@main
struct AgentsSessionHopperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AgentsSessionHopperApp.makeModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model, openSettings: Self.openSettings)
                .background(PopoverWindowReader())  // the Ko-fi card's moment is this window closing (SupportPrompt.swift)
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
        SupportPrompt.shared.start(model: model)
        DispatchQueue.main.async {
            WelcomeWindow.showIfNeeded(model: model)
            model.checkLogins()
        }
        return model
    }
}

/// Template glyph; a badge when a session needs you, a warning past the park threshold.
struct MenuBarLabel: View {
    static let showPercentKey = "showPercentInMenuBar"
    /// What the percentage next to the icon covers (`Mode`); the chosen profiles are `chosenKey`, comma-separated.
    static let modeKey = "menuBarPercentMode"
    static let chosenKey = "menuBarProfiles"
    enum Mode: String, CaseIterable {
        case fullest, eachActive, chosen, off
        var title: String {
            switch self {
            case .fullest: return "Fullest profile in use"
            case .eachActive: return "Each profile in use"
            case .chosen: return "Profiles I choose"
            case .off: return "Nothing"
            }
        }
    }
    @ObservedObject var model: AppModel
    @AppStorage(showPercentKey) private var showPercent = true
    @AppStorage(modeKey) private var modeRaw = ""
    @AppStorage(chosenKey) private var chosen = ""

    /// Before 1.16 only an on/off switch existed: off stays off.
    private var mode: Mode { Mode(rawValue: modeRaw) ?? (showPercent ? .fullest : .off) }

    var body: some View {
        let s = model.snapshot
        let full = (s.worstLivePercent ?? 0) >= model.config.hardThreshold
        let label = spoken(s, full: full)
        HStack(spacing: 3) {
            if !s.needsAttention.isEmpty {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
            } else if full {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            } else {
                Image(nsImage: Self.glyph)
            }
            switch mode {
            case .fullest: if let p = s.worstLivePercent { Text(percentText(p)).monospacedDigit() }
            case .eachActive, .chosen: if !items(s).isEmpty { Text(items(s).map { "\($0.short) \(percentText($0.pct))" }.joined(separator: " ")).monospacedDigit() }
            case .off: EmptyView()
            }
        }
        .accessibilityLabel(label)
        .help(label)
    }

    /// The profiles shown in `eachActive` / `chosen` mode, in profile order, each with the shortest name start that is
    /// unique among them (a label set with `profiles label` keeps it short).
    private func items(_ s: HopperSnapshot) -> [(name: String, short: String, pct: Double?)] {
        let active = Set(s.sessions.map(\.record.profile))
        let picked = Set(chosen.split(separator: ",").map(String.init))
        let shown = model.config.profiles.filter { mode == .chosen ? picked.contains($0.name) : active.contains($0.name) }
        let names = shown.map(\.displayName)
        return shown.enumerated().map { i, p in (p.displayName, Self.shortName(names[i], among: names), s.percent(p.name)) }
    }

    /// 1–6 characters: the shortest start of `name` no other name in `names` begins with.
    static func shortName(_ name: String, among names: [String]) -> String {
        for n in 1...6 where !names.contains(where: { $0 != name && $0.lowercased().hasPrefix(name.prefix(n).lowercased()) }) {
            return String(name.prefix(n))
        }
        return String(name.prefix(6))
    }

    /// One string for VoiceOver and the tooltip: the percent and the full state are not drawn text a label could inherit.
    private func spoken(_ s: HopperSnapshot, full: Bool) -> String {
        var text = "AgentsSessionHopper"
        if mode == .eachActive || mode == .chosen {
            text += items(s).map { ", \($0.name) \($0.pct.map { "\(Int($0.rounded())) percent" } ?? "unknown")" }.joined()
        } else if let p = s.worstLivePercent { text += ", fullest profile \(Int(p.rounded())) percent" }
        if !s.needsAttention.isEmpty { text += ", a session needs you" }
        if full { text += ", a profile is full" }
        return text
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
        MainActor.assumeIsolated {
            StatusMenu.shared.install()
            HotkeyCenter.register(Hotkey.saved)
            // The menu-bar panel opens only on a click or the hotkey (user actions): force the activation when it becomes key.
            // SwiftUI's own activation may be the request macOS 14+ refuses; a menu in the panel then forces it and closes
            // (traced in PullPing). The panel window comes from PopoverWindowReader (SupportPrompt.swift).
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
                let w = note.object as? NSWindow
                MainActor.assumeIsolated {
                    if let w, w === SupportPrompt.shared.popover { NSApp.activate(ignoringOtherApps: true) }
                }
            }
            // Sparkle asks on the second launch before any check; never under the debug hook or a bare `swift run`.
            if ProcessInfo.processInfo.environment["ASH_DEBUG_OPEN"] == nil, Bundle.main.bundleIdentifier != nil {
                _ = Updates.controller
            }
        }
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
