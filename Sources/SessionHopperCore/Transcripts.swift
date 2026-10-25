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
        /// The name `/resume` shows: `customTitle` (from `/rename`) else the automatic `aiTitle`.
        public var title: String?
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

    /// Resumable sessions recorded in `cwd` (or in every directory with `allDirs`), newest first, minus `live` ones.
    public static func list(cwd: String, projects: URL, live: Set<String>, limit: Int, allDirs: Bool = false) -> [Info] {
        let fm = FileManager.default
        let dirs = allDirs
            ? ((try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [])
            : [projects.appendingPathComponent(dirName(for: cwd))]
        var urls: [URL] = []
        for d in dirs { urls += (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }
        let files: [(URL, Date)] = urls
            .filter { $0.pathExtension == "jsonl" && !live.contains($0.deletingPathExtension().lastPathComponent) }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        var out: [Info] = []
        for (url, date) in files where out.count < limit {
            let head = scan(url)
            guard !head.sidechain, let prompt = head.prompt else { continue }
            out.append(Info(id: url.deletingPathExtension().lastPathComponent, modified: date, firstPrompt: prompt, cwd: head.cwd, title: title(of: url)))
        }
        return out
    }

    /// A session by the name `/resume` shows (exact match), newest first: this directory, then any.
    public static func resolve(name: String, cwd: String, projects: URL, live: Set<String>) -> String? {
        for all in [false, true] {
            if let hit = list(cwd: cwd, projects: projects, live: live, limit: .max, allDirs: all).first(where: { $0.title == name }) { return hit.id }
        }
        return nil
    }

    private static let titlePattern = try! NSRegularExpression(pattern: #""(customTitle|aiTitle)":"((?:[^"\\]|\\.)*)""#)

    /// Titles are re-written through the transcript, so the last 64 KB hold the current one.
    // shortcut: a title set once and never repeated in the last 64 KB is missed; read more if that shows up.
    static func title(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        var found: [String: String] = [:]
        for m in titlePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let k = Range(m.range(at: 1), in: text), let v = Range(m.range(at: 2), in: text),
                  let s = try? JSONSerialization.jsonObject(with: Data("\"\(text[v])\"".utf8), options: .fragmentsAllowed) as? String else { continue }
            found[String(text[k])] = s
        }
        return found["customTitle"] ?? found["aiTitle"]
    }

    public static func cwd(of url: URL) -> String? { scan(url).cwd }

    /// Did the conversation's last turn end with Claude Code's reply written? Decided by the last main-thread
    /// message or turn-end marker in the transcript tail: an `end_turn` reply, a user interrupt or a Stop
    /// marker = finished; a tool result, an unanswered prompt or a pending tool call = cut off. Slash commands,
    /// `<…>` system-injected prompts and meta entries don't decide. No transcript, or nothing recognisable
    /// = finished: the format is not a documented interface, so unknown means "today's behavior".
    public static func turnFinished(_ url: URL?) -> Bool {
        guard let url, let h = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
        // A cut-off first line fails to parse and is skipped.
        for line in ((try? h.readToEnd()) ?? Data()).split(separator: UInt8(ascii: "\n")).reversed() {
            guard let rec = FileIO.jsonObject(Data(line)), rec["isSidechain"] as? Bool != true else { continue }
            switch rec["type"] as? String {
            case "system":
                if ["turn_duration", "stop_hook_summary"].contains(rec["subtype"] as? String ?? "") { return true }
            case "assistant":
                if rec["isApiErrorMessage"] as? Bool == true { return false }
                // "No response requested." is what Claude Code writes on resume after a cut-off: that one was handled.
                return (rec["message"] as? [String: Any])?["stop_reason"] as? String == "end_turn"
                    || text(of: rec).trimmingCharacters(in: .whitespacesAndNewlines) == "No response requested."
            case "user":
                if ["isMeta", "isCompactSummary", "isVisibleInTranscriptOnly"].contains(where: { rec[$0] as? Bool == true }) { continue }
                let t = text(of: rec).trimmingCharacters(in: .whitespacesAndNewlines)
                if t.hasPrefix("<") || t.hasPrefix("/") { continue }
                return t.hasPrefix("[Request interrupted by user")
            default:
                continue
            }
        }
        return true
    }

    static func text(of rec: [String: Any]) -> String {
        let msg = rec["message"] as? [String: Any]
        if let s = msg?["content"] as? String { return s }
        return (msg?["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
    }

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

/// The numbered resume picker: pages of `page` rows, "m" for the next page, a number picks a row on
/// screen, anything else (or end of input) cancels. Numbering runs on across pages.
public enum Picker {
    public static func choose(count: Int, page: Int = 10, row: (Int) -> String, read: () -> String?, write: (String) -> Void) -> Int? {
        var shown = 0
        while true {
            let end = min(shown + page, count)
            let width = String(end).count
            for i in shown..<end { write(String(repeating: " ", count: width - String(i + 1).count) + "\(i + 1). \(row(i))\n") }
            shown = end
            let more = shown < count
            write(more ? "Resume which? number, m for more, Enter to cancel: " : "Resume which? number, Enter to cancel: ")
            guard let line = read()?.trimmingCharacters(in: .whitespaces) else { return nil }
            if line == "m", more { continue }
            guard let n = Int(line), (1...shown).contains(n) else { return nil }
            return n - 1
        }
    }
}
