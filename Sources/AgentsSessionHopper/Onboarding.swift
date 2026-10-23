import ServiceManagement
import SessionHopperCore
import SwiftUI

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// First run: what the app does and never does, then profiles. Shown once; again from Settings → General.
@MainActor enum OnboardingWindow {
    static let doneKey = "onboardingDone"
    private static var window: NSWindow?

    static func showIfNeeded(model: AppModel) {
        if !UserDefaults.standard.bool(forKey: doneKey) { show(model: model) }
    }

    static func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(model: model) { close() }))
            w.title = "Welcome to AgentsSessionHopper"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() {
        UserDefaults.standard.set(true, forKey: doneKey)
        window?.close()
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    var done: () -> Void = {}
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Profiles for Claude Code").font(.title2.bold())
            Text("⚠️ " + HopperInfo.betaNotice).font(.callout.bold()).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text("Keep your own Claude accounts side by side, one Claude Code profile each. When one runs low, you are asked whether to continue the conversation on another. Nothing moves until you confirm.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Starts the official, unmodified `claude`, one config folder per account.", systemImage: "checkmark")
                    Label("Never reads, stores or sends your Claude login, tokens or Keychain items.", systemImage: "checkmark")
                    Label("Makes no network requests. Usage comes only from Claude Code's own status line.", systemImage: "checkmark")
                    Label("Use it only with accounts that are yours, never shared with anyone.", systemImage: "person.fill.checkmark")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            Text("Your profiles").font(.headline)
            if model.config.profiles.isEmpty && model.discovered.isEmpty {
                Text("No Claude Code profile found yet. Add one, or run `claude` once first.").foregroundStyle(.secondary)
            }
            ForEach(model.config.profiles) { p in
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                    Text(p.name)
                    Text(model.tilde(p.dir)).foregroundStyle(.secondary)
                    Spacer()
                    LoginBadge(model: model, profile: p)
                }
            }
            let found = model.discovered
            if !found.isEmpty {
                HStack {
                    Text("Found: " + found.map { "\($0.name) (\(model.tilde($0.dir)))" }.joined(separator: ", "))
                    Spacer()
                    Button("Use these") { model.importDiscovered(); model.checkLogins() }
                }
            }
            HStack {
                Button("Add Profile…") { adding = true }
                Spacer()
            }

            Text("Tip: want a hard stop at your plan limit? Turn off extra usage in your Claude account settings. Claude Code then stops at the limit, and you are asked whether to continue on another profile.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Text(HopperInfo.disclaimer).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .sheet(isPresented: $adding) { AddProfileSheet(model: model, isPresented: $adding) }
    }
}
