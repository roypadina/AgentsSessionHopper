// AgentsSessionHopper demo: the app's real PopoverView + AppModel (PopoverView.swift / AppModel.swift, compiled from the app's sources)
// over the real SessionHopperCore engine types, filled with a fake snapshot. The clock is fake: every time in the snapshot is
// "today" at a fixed hour, so the panel's "resets 12:30" / "09:54" texts never depend on when the demo is rendered.
import AppKit
import SessionHopperCore
import SwiftUI

private let base = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
private func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Double { base + Double(h * 3600 + m * 60 + s) }
private func iso(_ t: Double) -> String {  // like FileIO.isoNow: local offset, parsed back by AppModel.swift eventTime
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = .current
    return f.string(from: Date(timeIntervalSince1970: t))
}

// MARK: - fake snapshot (the real engine types; a LiveSession has no public init, so it is decoded from the JSON the supervisor writes)

private let cwdApp = "/Users/me/Code/app", cwdSite = "/Users/me/Code/site"

private func live(_ id: String, profile: String, cwd: String, busy: Bool, pending: [String: Any]? = nil, suggestion: [String: Any]? = nil) -> LiveSession {
    var o: [String: Any] = ["record": ["session": id, "resume": id, "pid": 1, "child": 2, "profile": profile, "cwd": cwd, "started": "2026-10-30T07:30:00Z"],
                            "busy": busy, "held": false]
    if let pending { o["pending"] = pending }
    if let suggestion { o["suggestion"] = suggestion }
    return try! JSONDecoder().decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: o))
}

private enum Stage { case calm, asks, queued, moved }

private func snapshot(_ stage: Stage) -> HopperSnapshot {
    var config = HopperConfig()  // thresholds stay the defaults: suggest at 85 %, park at 97 % (Config.swift)
    config.profiles = [Profile(name: "Work", dir: "/Users/me/.claude-work", exportConfigDir: true),
                       Profile(name: "Personal", dir: "/Users/me/.claude", exportConfigDir: false)]
    let now: Double, work5: Double, personal5: Double, workSample: Double, personalSample: Double
    switch stage {
    case .calm:   (now, work5, personal5, workSample, personalSample) = (at(9, 41), 71, 24, at(9, 40, 40), at(9, 38))
    case .asks:   (now, work5, personal5, workSample, personalSample) = (at(9, 52), 87, 24, at(9, 51, 50), at(9, 49))
    case .queued: (now, work5, personal5, workSample, personalSample) = (at(9, 52, 20), 87, 24, at(9, 52, 10), at(9, 49))
    case .moved:  (now, work5, personal5, workSample, personalSample) = (at(9, 54, 10), 87, 27, at(9, 52, 10), at(9, 54))
    }
    let limits = [
        "Work": ProfileLimits(fiveHour: LimitWindow(usedPercentage: work5, resetsAt: at(12, 30)),
                              sevenDay: LimitWindow(usedPercentage: 38, resetsAt: at(9, 41) + 5 * 86400), sampledAt: workSample),
        "Personal": ProfileLimits(fiveHour: LimitWindow(usedPercentage: personal5, resetsAt: at(13, 10)),
                                  sevenDay: LimitWindow(usedPercentage: 12, resetsAt: at(9, 41) + 4 * 86400), sampledAt: personalSample),
    ]
    let app: LiveSession
    switch stage {
    case .calm: app = live("a1", profile: "Work", cwd: cwdApp, busy: true)
    case .asks: app = live("a1", profile: "Work", cwd: cwdApp, busy: true,
                           suggestion: ["from": "Work", "to": "Personal", "percent": 87.0, "reason": "threshold", "dismissed": false])
    case .queued: app = live("a1", profile: "Work", cwd: cwdApp, busy: true, pending: ["to": "Personal", "trigger": "confirm", "source": "menu"])
    case .moved: app = live("a1", profile: "Personal", cwd: cwdApp, busy: false)  // a turn-end move adds no prompt (Supervisor.swift:161-169): idle until the next UserPromptSubmit (HookHandler.swift:57)
    }
    let site = live("b2", profile: "Personal", cwd: cwdSite, busy: false)
    var events: [HopperEvent] = []
    if stage != .calm {
        events.append(HopperEvent(type: "suggest", session: "a1", cwd: cwdApp, from: "Work", to: "Personal", trigger: "threshold", source: "engine", ts: iso(at(9, 51, 48))))
    }
    if stage == .moved {
        events.append(HopperEvent(type: "switch", session: "a1", cwd: cwdApp, from: "Work", to: "Personal", trigger: "confirm", source: "menu", ts: iso(at(9, 54, 2))))
    }
    return HopperSnapshot(config: config, limits: limits, sessions: [app, site], events: events, now: now)
}

// MARK: - the panel: AgentsSessionHopperApp.swift:10-22, the MenuBarExtra(.window) content

private struct PanelContent: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack {
            PopoverView(model: model, openSettings: {})
            Divider()
            HStack {
                Button("About") {}                                       // AgentsSessionHopperApp.swift:14
                Button("Support on Ko-fi ☕") {}                          // :15
                Spacer()
                Button("Quit AgentsSessionHopper") {}.keyboardShortcut("q")  // :17
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }
}

/// Same look as the kit's renderView (transparent, dark, 2x), but drawn by a real NSHostingView in a window that is never shown (the way
/// the app's own ScreenshotRenderTests render PopoverView): ImageRenderer draws a placeholder for AppKit-backed controls (the borderless
/// buttons and the "Move…" menu). The tint pins the system-blue default, so the render does not depend on this Mac's accent colour setting.
@MainActor private func renderHosted<V: View>(_ view: V) -> CGImage {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).environment(\.controlActiveState, .key))
    host.appearance = NSAppearance(named: .darkAqua)
    let size = host.fittingSize
    host.frame = CGRect(origin: .zero, size: size)
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.isOpaque = false; win.backgroundColor = .clear; win.appearance = NSAppearance(named: .darkAqua)
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))  // lets the AppKit-backed controls build before the capture
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * Demo.scale).rounded(.up)), pixelsHigh: Int((size.height * Demo.scale).rounded(.up)),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep.cgImage!
}

// MARK: - status item: AgentsSessionHopperApp.swift:49-72 MenuBarLabel (badge / warning / template glyph, then the fullest live percent)

private func glyphSlot(_ width: CGFloat) -> String {  // reserves the glyph's width in the kit's status item; the glyph is drawn over it
    var s = ""
    while (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width < width { s += " " }
    return s
}

private let glyph: CGImage = {  // Assets/icons/menubar@2x.png (the app's template glyph), tinted like a menu bar template image
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ASH_ICONS"]! + "/menubar@2x.png")
    let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    ctx.draw(img, in: r); ctx.setBlendMode(.sourceIn); ctx.setFillColor(CGColor(gray: 1, alpha: 0.95)); ctx.fill(r)
    return ctx.makeImage()!
}()

/// A monochrome SF Symbol (no palette, so the badge's arrows stay cut out of its disc), tinted like a menu bar template image. The kit's own
/// StatusItem(symbol:) paints the symbol's layers white, which fills the badge's arrows in on its white disc.
private func symbolGlyph(_ name: String) -> (image: CGImage, size: CGSize) {
    let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))!
    let w = Int((sym.size.width * Demo.scale).rounded(.up)), h = Int((sym.size.height * Demo.scale).rounded(.up))
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    sym.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    ctx.setBlendMode(.sourceIn); ctx.setFillColor(CGColor(gray: 1, alpha: 0.95)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return (ctx.makeImage()!, sym.size)
}
private let badgeGlyph = symbolGlyph("arrow.triangle.2.circlepath.circle.fill")                // AgentsSessionHopperApp.swift:61
private let fullGlyph = symbolGlyph("exclamationmark.arrow.triangle.2.circlepath")             // :63 (past the park threshold; not reached in this demo)

@MainActor private func drawBar(_ c: Canvas, _ s: HopperSnapshot, active: Bool, clock: String) -> CGRect {
    let full = (s.worstLivePercent ?? 0) >= s.config.hardThreshold
    let pct = s.worstLivePercent.map { percentText($0) }  // showPercent defaults to true (@AppStorage, :53)
    let g: (image: CGImage, size: CGSize) = !s.needsAttention.isEmpty ? badgeGlyph : full ? fullGlyph : (glyph, CGSize(width: 18, height: 18))
    let f = c.menuBar(app: StatusItem(text: glyphSlot(g.size.width + 3) + (pct ?? "")), appActive: active, clock: clock)  // glyph + the app's 3 pt HStack gap
    c.draw(g.image, in: CGRect(x: f.minX + 8, y: (Demo.barHeight - g.size.height) / 2, width: g.size.width, height: g.size.height))
    return f
}

/// Centre (canvas points, relative to the image) of the accent-filled button in a rendered panel, so the cursor points at the real one.
private func accentButtonCenter(_ img: CGImage) -> CGPoint {
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, maxX = -1, minY = h, maxY = -1
    for y in 0..<h { for x in 0..<w {
        let i = (y * w + x) * 4
        if px[i + 3] > 250, px[i + 2] > 220, px[i] < 70, px[i + 1] > 90, px[i + 1] < 170 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
    } }
    precondition(maxX >= 0, "no accent button found in the rendered panel")
    return CGPoint(x: CGFloat(minX + maxX) / 2 / Demo.scale, y: CGFloat(minY + maxY) / 2 / Demo.scale)
}

private let W = Demo.size.width, H = Demo.size.height

@MainActor func ashScenes() -> [Scene] {
    let env = HopperEnvironment(home: URL(fileURLWithPath: "/Users/me"), stateDir: FileManager.default.temporaryDirectory.appendingPathComponent("ash-demo-no-state"),
                                selfPath: "/Applications/AgentsSessionHopper.app/Contents/Helpers/sessionhopper")
    let model = AppModel(env: env, autoRefresh: false)
    func stage(_ s: Stage) -> (snap: HopperSnapshot, panel: CGImage) {
        let snap = snapshot(s)
        model.snapshot = snap
        return (snap, renderHosted(PanelContent(model: model)))
    }
    let calm = stage(.calm), asks = stage(.asks), queued = stage(.queued), moved = stage(.moved)
    let item = drawBar(Canvas(background: nil), calm.snap, active: false, clock: Demo.clock)
    let panelW = CGFloat(calm.panel.width) / Demo.scale
    // MenuBarExtra(.window) opens centred under its status item, kept 8 pt inside the screen edge
    let origin = CGPoint(x: min(item.midX - panelW / 2, W - panelW - 8), y: Demo.barHeight + 6)
    let barCenter = CGPoint(x: item.midX, y: Demo.barHeight / 2)
    let btn = accentButtonCenter(asks.panel)
    let moveButton = CGPoint(x: origin.x + btn.x + 52, y: origin.y + btn.y)  // right of centre: the pointer does not hide the label
    let desktop = CGPoint(x: W * 0.30, y: H * 0.50)
    let panelRadius: CGFloat = 20
    let clock952 = "Thu Oct 30 9:52 AM", clock954 = "Thu Oct 30 9:54 AM"

    // 1. the status item: the fullest profile's usage
    let s1 = Scene(name: "menu bar", duration: 2.0, caption: "Your fullest profile's usage sits in the menu bar") { _ in
        let c = Canvas()
        _ = drawBar(c, calm.snap, active: false, clock: Demo.clock)
        return c.image
    }

    // State changes land inside a scene, never on a scene boundary: the kit crossfades boundaries, and two different panels
    // dissolved into each other would ghost. A real MenuBarExtra panel updates instantly when its model changes.

    // 2. click opens the panel at once: profiles with 5 h / 7 d usage, live sessions; late in the scene Work crosses 85 %
    let path2 = CursorPath(start: CGPoint(x: W * 0.62, y: H * 0.46), moves: [.init(t0: 0.10, t1: 0.75, to: barCenter)], clicks: [0.85])
    let s2 = Scene(name: "panel", duration: 3.2, caption: "See each profile's usage and its live sessions") { t in
        let c = Canvas()
        let open = t >= 0.85, nears = t >= 2.7
        let st = nears ? asks : calm
        _ = drawBar(c, st.snap, active: open, clock: nears ? clock952 : Demo.clock)
        if open { c.panel(st.panel, at: origin, radius: panelRadius, alpha: CGFloat(ramp(t, 0.85, 0.97))) }
        let click = path2.click(t)
        c.cursor(at: path2.position(t), alpha: CGFloat(ramp(t, 0.0, 0.25) * (1 - ramp(t, 1.55, 1.75))), press: click.press, pulse: click.pulse)
        return c.image
    }

    // 3. the badge and the "Needs you" card are up; the cursor goes for the real button
    let path3 = CursorPath(start: CGPoint(x: origin.x + 330, y: origin.y + 70), moves: [.init(t0: 1.00, t1: 1.65, to: moveButton)])
    let s3 = Scene(name: "asks", duration: 2.4, caption: "Near its limit, it asks to continue elsewhere") { t in
        let c = Canvas()
        _ = drawBar(c, asks.snap, active: true, clock: clock952)
        c.panel(asks.panel, at: origin, radius: panelRadius)
        c.cursor(at: path3.position(t), alpha: CGFloat(ramp(t, 0.95, 1.15)))
        return c.image
    }

    // 4. Move: the card is answered at once and the row says it moves at turn end; at the turn end the session runs on Personal
    let path4 = CursorPath(start: moveButton, moves: [], clicks: [0.35])
    let s4 = Scene(name: "confirm", duration: 2.4, caption: "Confirm, and it moves when the turn ends") { t in
        let c = Canvas()
        let st = t >= 1.9 ? moved : t >= 0.40 ? queued : asks  // 0.40: AppModel.confirmMove -> act -> refresh(), the next render has the pending move
        _ = drawBar(c, st.snap, active: true, clock: t >= 1.9 ? clock954 : clock952)
        c.panel(st.panel, at: origin, radius: panelRadius)
        let click = path4.click(t)
        c.cursor(at: path4.position(t), alpha: CGFloat(1 - ramp(t, 0.95, 1.15)), press: click.press, pulse: click.pulse)
        return c.image
    }

    // 5. the same conversation runs on Personal, the hand-off is logged; a click on the desktop closes the panel
    let path5 = CursorPath(start: CGPoint(x: W * 0.55, y: H * 0.62), moves: [.init(t0: 1.05, t1: 1.55, to: desktop)], clicks: [1.65])
    let s5 = Scene(name: "moved", duration: 2.6, caption: "Same conversation, continued on the other profile") { t in
        let c = Canvas()
        let fade = ramp(t, 1.75, 1.87)  // MenuBarExtra closes its panel on a click outside
        _ = drawBar(c, moved.snap, active: fade == 0, clock: clock954)
        if fade < 1 { c.panel(moved.panel, at: origin, radius: panelRadius, alpha: CGFloat(1 - fade)) }
        let click = path5.click(t)
        c.cursor(at: path5.position(t), alpha: CGFloat(ramp(t, 1.00, 1.15) * (1 - ramp(t, 1.90, 2.10))), press: click.press, pulse: click.pulse)
        return c.image
    }
    return [s1, s2, s3, s4, s5]
}

@main struct AgentsSessionHopperDemo {
    @MainActor static func main() { Demo.run(scenes: ashScenes()) }
}
