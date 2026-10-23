import Foundation

/// One line of the switch log (`events.jsonl`). Schema v1: additive changes only, readers ignore
/// unknown keys.
public struct HopperEvent: Codable, Equatable, Sendable, Identifiable {
    public var v: Int = 1
    public var ts: String
    /// switch | park | limit | suggest
    public var type: String
    public var session: String?
    public var cwd: String?
    public var from: String?
    public var to: String?
    /// confirm | auto | limit_stop | park | now | threshold | limit
    public var trigger: String?
    /// menu | notification | cli | engine | hook
    public var source: String?
    public var detail: String?
    /// Every profile's last-known numbers at that moment.
    public var profiles: [String: ProfileSample]?

    public var id: String { ts + type + (session ?? "") }

    public init(type: String, session: String? = nil, cwd: String? = nil, from: String? = nil, to: String? = nil,
                trigger: String? = nil, source: String? = nil, detail: String? = nil,
                profiles: [String: ProfileSample]? = nil, ts: String? = nil) {
        self.ts = ts ?? FileIO.isoNow()
        self.type = type
        self.session = session
        self.cwd = cwd
        self.from = from
        self.to = to
        self.trigger = trigger
        self.source = source
        self.detail = detail
        self.profiles = profiles
    }
}

public struct ProfileSample: Codable, Equatable, Sendable {
    public var dir: String
    public var fiveHour: Double?
    public var sevenDay: Double?
    public var sampledAt: Double?

    enum CodingKeys: String, CodingKey {
        case dir
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sampledAt = "sampled_at"
    }
}

public enum EventLog {
    public static func append(_ event: HopperEvent, _ paths: StatePaths) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(event), let line = String(data: data, encoding: .utf8) else { return }
        FileIO.appendLine(line, to: paths.events)
    }

    /// Newest last.
    // shortcut: reads the whole file; fine for months of hand-offs, trim or tail-read when retention lands.
    public static func read(_ paths: StatePaths, last n: Int? = nil) -> [HopperEvent] {
        guard let text = FileIO.readString(paths.events) else { return [] }
        let dec = JSONDecoder()
        let all = text.split(separator: "\n").compactMap { try? dec.decode(HopperEvent.self, from: Data($0.utf8)) }
        return n.map { Array(all.suffix($0)) } ?? all
    }

    public static func samples(_ config: HopperConfig, _ paths: StatePaths, now: Double) -> [String: ProfileSample] {
        var out: [String: ProfileSample] = [:]
        for p in config.profiles {
            let l = LimitStore.read(p.name, paths)
            out[p.name] = ProfileSample(dir: p.dir,
                                        fiveHour: l?.fiveHour.flatMap { $0.isLive(now: now) ? $0.usedPercentage : nil },
                                        sevenDay: l?.sevenDay.flatMap { $0.isLive(now: now) ? $0.usedPercentage : nil },
                                        sampledAt: l?.sampledAt)
        }
        return out
    }
}

extension EventLog {
    /// Drops entries older than `days`. Rewrites the file (temp + rename).
    public static func prune(_ paths: StatePaths, days: Int = 90, now: Date = Date()) {
        guard let text = FileIO.readString(paths.events) else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        let iso = ISO8601DateFormatter()
        let lines = text.split(separator: "\n")
        let kept = lines.filter { line in
            guard let ts = FileIO.jsonObject(Data(line.utf8))?["ts"] as? String, let d = iso.date(from: ts) else { return true }
            return d >= cutoff
        }
        guard kept.count != lines.count else { return }
        try? FileIO.write(kept.map { $0 + "\n" }.joined(), to: paths.events)
    }
}
