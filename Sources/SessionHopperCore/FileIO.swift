import Foundation

enum FileIO {
    static var fm: FileManager { .default }

    static func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    static func read(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    static func readString(_ url: URL) -> String? { read(url).flatMap { String(data: $0, encoding: .utf8) } }

    /// Temp file + rename, so a reader in another process never sees half a file.
    static func write(_ data: Data, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func write(_ text: String, to url: URL) throws { try write(Data(text.utf8), to: url) }

    static func touch(_ url: URL) { try? write(Data(), to: url) }

    static func remove(_ url: URL) { try? fm.removeItem(at: url) }

    /// Non-empty regular file.
    static func hasContent(_ url: URL) -> Bool {
        ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0 > 0
    }

    static func jsonObject(_ data: Data?) -> [String: Any]? {
        guard let data, !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        read(url).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func encode<T: Encodable>(_ value: T, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try write(enc.encode(value), to: url)
    }

    /// One line, appended with O_APPEND so concurrent writers (hooks, supervisor, app) never interleave.
    static func appendLine(_ line: String, to url: URL) {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
    }

    /// Single-quoted for /bin/sh.
    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        // Signal 0 checks liveness only; EPERM means alive but owned by someone else.
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static func now() -> Double { Date().timeIntervalSince1970 }

    static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: Date())
    }
}
