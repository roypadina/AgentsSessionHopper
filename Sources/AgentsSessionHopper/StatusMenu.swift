import AppKit
import SessionHopperCore

/// Right-click / control-click menu on the menu-bar icon. SwiftUI's MenuBarExtra has no hook for it,
/// so a local event monitor catches the click on the status-bar window, swallows it and pops an NSMenu.
@MainActor final class StatusMenu: NSObject {
    static let shared = StatusMenu()
    private var monitor: Any?
    private weak var button: NSView?

    static let requestFeature = URL(string: "https://github.com/roypadina/AgentsSessionHopper/issues/new?template=feature_request.yml")!
    static let contribute = URL(string: "https://github.com/roypadina/AgentsSessionHopper/blob/main/CONTRIBUTING.md")!

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  let view = event.window?.contentView,
                  String(describing: type(of: event.window!)).contains("NSStatusBarWindow") else { return event }
            self?.button = view
            NSMenu.popUpContextMenu(self?.menu() ?? NSMenu(), with: event, for: view)
            return nil
        }
    }

    func menu() -> NSMenu {
        let m = NSMenu()
        func item(_ title: String, _ action: Selector, key: String = "") {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            m.addItem(i)
        }
        item("Open", #selector(open))
        item("Settings…", #selector(settings), key: ",")
        item("Show Hand-off Log", #selector(switchLog))
        m.addItem(.separator())
        item("Request a feature", #selector(feature))
        item("Contribute", #selector(contribute))
        item("About AgentsSessionHopper", #selector(about))
        item("Support on Ko-fi ☕", #selector(kofi))
        m.addItem(.separator())
        item("Quit AgentsSessionHopper", #selector(quit), key: "q")
        return m
    }

    // Click the real status button (found under the status-bar window) to open the popover.
    @objc private func open() { (button?.subviews.first { $0 is NSButton } as? NSButton ?? button as? NSButton)?.performClick(nil) }
    @objc private func settings() { AgentsSessionHopperApp.openSettings() }
    @objc private func switchLog() {
        SettingsView.pendingTab = .log
        NotificationCenter.default.post(name: SettingsView.selectTab, object: nil)
        AgentsSessionHopperApp.openSettings()
    }
    @objc private func feature() { NSWorkspace.shared.open(Self.requestFeature) }
    @objc private func contribute() { NSWorkspace.shared.open(Self.contribute) }
    @objc private func about() { AboutWindow.show() }
    @objc private func kofi() { NSWorkspace.shared.open(HopperInfo.koFi) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
