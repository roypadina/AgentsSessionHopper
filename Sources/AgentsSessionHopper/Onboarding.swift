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
            w.title = "Set up AgentsSessionHopper"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        if let window { AccessoryWindows.shared.show(window) }
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
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text("Profiles for Claude Code").font(.title2.bold())
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

            Text("1. Your profiles").font(.headline)
            Text("One Claude Code folder per account. Log each one in with Claude Code's own login.")
                .font(.caption).foregroundStyle(.secondary)
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

            SetupSteps(model: model)

            Text("Tip: want a hard stop at your plan limit? Turn off extra usage in your Claude account settings. Claude Code then stops at the limit, and you are asked whether to continue on another profile.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Text(HopperInfo.disclaimer).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        }
        .frame(width: 560, height: 680)
        .sheet(isPresented: $adding) { AddProfileSheet(model: model, isPresented: $adding) }
    }
}

/// Steps 2–6 of the setup. Each shows what it changes and runs only on a click.
struct SetupSteps: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            step("2. Share history between profiles",
                 "A conversation can only continue on another profile if they share Claude Code's history folder. Also shared: todo lists, /rewind checkpoints, CLAUDE.md, agents, commands and skills. Existing folders are moved to a backup and merged, never deleted. Quit sessions on a profile first.")
            ForEach(model.config.profiles.dropFirst()) { p in
                HStack {
                    Text(p.name)
                    Spacer()
                    Button("Preview") { model.share(p, dryRun: true) }
                    Button("Share with \(model.config.profiles.first?.name ?? "")") { model.share(p, dryRun: false) }
                }
            }

            step("3. Make `claude` use AgentsSessionHopper",
                 "Adds one marked line to \(model.shellFile) (\(model.shellKind.rawValue)), after a backup. Works in any terminal app. Only sessions started this way can move; restart open ones once. Without it, start sessions with `sessionhopper`.")
            CopyRow(text: model.aliasLine)
            HStack {
                Label(model.shellInstalled ? "Set up" : "Not set up", systemImage: model.shellInstalled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.shellInstalled ? .green : .secondary)
                Spacer()
                if model.shellInstalled { Button("Remove the line") { model.setShell(false) } } else { Button("Add the line") { model.setShell(true) } }
            }

            step("4. cmux and JetBrains (optional)",
                 "Tools that ask for a Claude binary path get a link that behaves like `claude` but is supervised. Panes a terminal restores re-run their original command: restart them once. The VS Code side panel is not supported; use its terminal.")
            HStack {
                Text(model.tilde(Setup.shimLink(home: model.env.home).path)).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button(model.shimLinked ? "Linked" : "Create the link") { model.linkShim() }.disabled(model.shimLinked)
            }

            step("5. Teach Claude about it",
                 "Installs the agents-session-hopper skill from github.com/\(Setup.marketplace) into every profile, with Claude Code's own `claude plugin install`. Claude then knows which account it is on, how to switch or hold, and how to pick work back up after a move.")
            HStack {
                ForEach(model.config.profiles) { p in
                    Label(p.name, systemImage: model.pluginState[p.name] == true ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.pluginState[p.name] == true ? .green : .secondary)
                }
                Spacer()
                Button("Check") { model.checkPlugins() }
                Button("Install in every profile") { model.checkPlugins(install: true) }
            }

            step("6. Check everything", "Runs the same checks as `sessionhopper doctor`.")
            HStack {
                Button("Run the checks") { model.runDoctor() }
                if model.busy { ProgressView().controlSize(.small) }
            }
            ForEach(Array(model.doctor.enumerated()), id: \.offset) { _, c in
                Text("\(c.level == .ok ? "✓" : c.level == .info ? "·" : c.level == .warn ? "!" : "✗") \(c.message)")
                    .font(.caption).foregroundStyle(c.level == .warn || c.level == .fail ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.setupLog.isEmpty {
                GroupBox {
                    Text(model.setupLog.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func step(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
