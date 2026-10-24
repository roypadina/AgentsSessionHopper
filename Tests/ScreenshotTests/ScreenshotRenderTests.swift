import AppKit
import SwiftUI
import XCTest
@testable import AgentsSessionHopper
@testable import SessionHopperCore

/// Renders the app's views offscreen (a window that is never shown) into PNGs, from sample data in a
/// temp state dir. Dev-only, skipped unless RENDER_SCREENSHOTS=<output dir>:
///   RENDER_SCREENSHOTS=$PWD/docs/screenshots swift test --filter ScreenshotRenderTests
///   Scripts/strip_png_metadata.py docs/screenshots/*.png
@MainActor
final class ScreenshotRenderTests: XCTestCase {
    private func render<V: View>(_ view: V, name: String, dir: String, cropTop: Int = 0) throws {
        let host = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .aqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let scale = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        let cg = try XCTUnwrap(rep.cgImage)
        let crop = try XCTUnwrap(cg.cropping(to: CGRect(x: 0, y: cropTop * scale, width: cg.width, height: cg.height - cropTop * scale)))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    /// Sample state: three profiles, two live sessions (one with a suggestion), a few hand-offs.
    private func sampleModel() throws -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hopper-shots-\(UUID().uuidString.prefix(6))")
        let env = HopperEnvironment(home: URL(fileURLWithPath: "/Users/me"), stateDir: root, selfPath: "/Applications/AgentsSessionHopper.app/Contents/Helpers/sessionhopper")
        let p = env.paths
        var c = HopperConfig()
        c.profiles = [Profile(name: "personal", dir: "/Users/me/.claude", exportConfigDir: false),
                      Profile(name: "work", dir: "/Users/me/.claude-work", exportConfigDir: true),
                      Profile(name: "spare", dir: "/Users/me/.claude-spare", exportConfigDir: true)]
        try c.save(p)
        let now = Date().timeIntervalSince1970
        try LimitStore.write(ProfileLimits(fiveHour: LimitWindow(usedPercentage: 42, resetsAt: now + 7200),
                                           sevenDay: LimitWindow(usedPercentage: 61, resetsAt: now + 300_000), sampledAt: now - 180), profile: "personal", p)
        try LimitStore.write(ProfileLimits(fiveHour: LimitWindow(usedPercentage: 88, resetsAt: now + 5400),
                                           sevenDay: LimitWindow(usedPercentage: 30, resetsAt: now + 400_000), sampledAt: now - 60), profile: "work", p)
        let me = getpid()
        for (id, prof, cwd, busy) in [("1a2b3c4d-0000-0000-0000-000000000001", "work", "/Users/me/Code/app", true),
                                      ("5e6f7a8b-0000-0000-0000-000000000002", "personal", "/Users/me/Code/site", false)] {
            try FileIO.encode(SessionRecord(session: id, resume: id, pid: me, child: me, profile: prof, cwd: cwd, started: id), to: p.session(id).record)
            if busy { FileIO.touch(p.session(id).busy) }
        }
        try FileIO.encode(Suggestion(from: "work", to: "personal", percent: 88, reason: "threshold"), to: p.session("1a2b3c4d-0000-0000-0000-000000000001").suggest)
        let today = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        EventLog.append(HopperEvent(type: "limit", session: "9", cwd: "/Users/me/Code/api", from: "spare", trigger: "limit", source: "hook", ts: today), p)
        EventLog.append(HopperEvent(type: "switch", session: "9", cwd: "/Users/me/Code/api", from: "spare", to: "personal", trigger: "confirm", source: "menu", ts: today), p)
        EventLog.append(HopperEvent(type: "suggest", session: "1", cwd: "/Users/me/Code/app", from: "work", to: "personal", trigger: "threshold", source: "engine", ts: today), p)
        EventLog.append(HopperEvent(type: "park", session: "7", cwd: "/Users/me/Code/docs", from: "work", trigger: "park", source: "engine", ts: today), p)
        return (AppModel(env: env, autoRefresh: false), root)
    }

    func test_renderScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_SCREENSHOTS"] else {
            throw XCTSkip("set RENDER_SCREENSHOTS=<dir> to render")
        }
        let (model, root) = try sampleModel()
        defer { try? FileManager.default.removeItem(at: root) }
        AboutView.iconOverride = NSImage(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../Assets/icons/AppIcon-1024.png").standardizedFileURL)
        try render(OnboardingView(model: model).background(Color(nsColor: .windowBackgroundColor)), name: "onboarding.png", dir: dir)
        try render(PopoverView(model: model).background(Color(nsColor: .windowBackgroundColor)), name: "popover.png", dir: dir)
        for (tab, name) in [(SettingsView.Tab.general, "settings-general.png"), (.handOff, "settings-handoff.png"), (.profiles, "settings-profiles.png"),
                          (.commandLine, "settings-command-line.png"), (.log, "settings-log.png")] {
            try render(SettingsView(model: model, nav: { let n = SettingsNav(); n.tab = tab; return n }()).background(Color(nsColor: .windowBackgroundColor)).frame(width: 600, height: 480), name: name, dir: dir)
        }
        try render(AboutView().background(Color(nsColor: .windowBackgroundColor)), name: "about.png", dir: dir)
    }

    /// Always runs: the views build and lay out with sample data.
    func test_viewsLayOut() throws {
        let (model, root) = try sampleModel()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(model.snapshot.needsAttention.count, 1)
        XCTAssertEqual(model.snapshot.worstLivePercent, 88)
        XCTAssertEqual(model.severity("work"), .near)
        XCTAssertEqual(model.severity("spare"), .unknown)
        let size = NSHostingView(rootView: PopoverView(model: model)).fittingSize
        XCTAssertEqual(size.width, 400)
        XCTAssertGreaterThan(size.height, 200)
        model.moveProfile("spare", by: -1)
        XCTAssertEqual(model.config.profiles.map(\.name), ["personal", "spare", "work"])
        model.confirmMove(model.snapshot.needsAttention[0])
        XCTAssertEqual(model.snapshot.sessions.first { $0.record.profile == "work" }?.pending?.to, "personal")
        XCTAssertTrue(model.snapshot.needsAttention.isEmpty)
    }
}
