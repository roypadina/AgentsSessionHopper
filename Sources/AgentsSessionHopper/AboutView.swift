import SessionHopperCore
import SwiftUI

/// Custom About window (the standard panel's fixed-height credits box clips the text).
@MainActor enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
            w.title = "About AgentsSessionHopper"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        if let window { AccessoryWindows.shared.show(window) }
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: AboutView.icon)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(spacing: 2) {
                Text("AgentsSessionHopper").font(.title.bold())
                Text("Version \(HopperInfo.version)").font(.callout).foregroundStyle(.secondary)
            }

            Text("Profiles for Claude Code. Keep your own accounts side by side, and when one runs low, continue the conversation on another with one click.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                Text("Made by Roy Padina").font(.headline)
                Text("I'm a software engineer from Israel who builds small, focused Mac tools to fix the little annoyances in my own day — then shares them free and open source.")
                Text("If this app saves you time, a coffee on Ko-fi keeps the next one coming. ☕")
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Link(destination: HopperInfo.koFi) { Text("Support on Ko-fi ☕").frame(minWidth: 140) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Link(destination: HopperInfo.repo) { Text("GitHub").frame(minWidth: 70) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }

            Link("Report an issue", destination: HopperInfo.repo.appendingPathComponent("issues")).font(.callout)

            Divider()

            VStack(spacing: 8) {
                Text("Have an idea, or want to help build it?").font(.headline)
                Text("Feature requests and pull requests are welcome. Ko-fi supporters go to the front of the queue.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Link(destination: URL(string: "https://github.com/roypadina/AgentsSessionHopper/issues/new?template=feature_request.yml")!) {
                        Text("Request a feature").frame(minWidth: 120)
                    }
                    .buttonStyle(.bordered)

                    Link(destination: URL(string: "https://github.com/roypadina/AgentsSessionHopper/blob/main/CONTRIBUTING.md")!) {
                        Text("Contribute").frame(minWidth: 90)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text(HopperInfo.disclaimer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("© Roy Padina · MIT").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 400)
    }
}

extension AboutView {
    /// Set by the screenshot renderer, which runs outside the app bundle.
    nonisolated(unsafe) static var iconOverride: NSImage?

    static var icon: NSImage {
        if let iconOverride { return iconOverride }
        if Bundle.main.bundleIdentifier != nil, let app = NSApp { return app.applicationIconImage }
        return NSImage(systemSymbolName: "arrow.triangle.swap", accessibilityDescription: nil)!
    }
}
