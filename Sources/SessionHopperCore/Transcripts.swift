import Foundation

/// Claude Code's session transcripts: `<config>/projects/<cwd with every non-alphanumeric as "-">/<id>.jsonl`.
/// The layout is not a documented interface; it is used only to list resumable sessions and to find the
/// directory a session belongs to. Hand-off itself only needs `claude --resume <id>`.
public enum Transcripts {
    public struct Info: Equatable, Sendable {
        public var id: String
        public var modified: Date
        public var firstPrompt: String
        public var cwd: String?
    }

    public static func dirName(for cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "-" })
    }

    public static func find(_ id: String, projects: URL) -> URL? {
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(atPath: projects.path)) ?? [] {
            let url = projects.appendingPathComponent(dir).appendingPathComponent("\(id).jsonl")
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Resumable sessions recorded in `cwd`, newest first, minus `live` ones.
    public static func list(cwd: String, projects: URL, live: Set<String>, limit: Int) -> [Info] {
        let dir = projects.appendingPathComponent(dirName(for: cwd))
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" && !live.contains($0.deletingPathExtension().lastPathComponent) }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        var out: [Info] = []
        for (url, date) in files where out.count < limit {
            let head = scan(url)
            guard !head.sidechain, let prompt = head.prompt else { continue }
            out.append(Info(id: url.deletingPathExtension().lastPathComponent, modified: date, firstPrompt: prompt, cwd: head.cwd))
        }
        return out
    }

    public static func cwd(of url: URL) -> String? { scan(url).cwd }

    /// First user prompt and cwd, from the first 256 KB.
    static func scan(_ url: URL) -> (prompt: String?, cwd: String?, sidechain: Bool) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return (nil, nil, false) }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 256 * 1024)) ?? Data()
        var cwd: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let rec = FileIO.jsonObject(Data(line)) else { continue }
            if rec["isSidechain"] as? Bool == true { return (nil, cwd, true) }
            cwd = cwd ?? rec["cwd"] as? String
            guard rec["type"] as? String == "user", let msg = rec["message"] as? [String: Any] else { continue }
            var text = msg["content"] as? String
            if text == nil, let blocks = msg["content"] as? [[String: Any]] {
                text = blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
            }
            if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<") {
                return (t.split(whereSeparator: \.isWhitespace).joined(separator: " "), cwd, false)
            }
        }
        return (nil, cwd, false)
    }

    /// Conversations held open right now: ours, plus Claude Code's own `<config>/sessions/<pid>.json`
    /// registry (undocumented, best effort). A live one must not be resumed a second time.
    public static func liveIDs(config: HopperConfig, paths: StatePaths) -> Set<String> {
        var ids = Set(Sessions.live(paths).flatMap { [$0.record.session, $0.record.resume] })
        for p in config.profiles {
            let dir = URL(fileURLWithPath: p.dir).appendingPathComponent("sessions")
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
                guard let rec = FileIO.jsonObject(FileIO.read(f)),
                      let pid = (rec["pid"] as? NSNumber)?.int32Value, let sid = rec["sessionId"] as? String,
                      FileIO.isAlive(pid) else { continue }
                ids.insert(sid)
            }
        }
        return ids
    }
}
