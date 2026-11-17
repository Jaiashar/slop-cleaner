import Foundation

/// What the Claude app records about one of its Claude Code sessions. Read-only: Watcher never writes these.
struct ClaudeSessionRecord: Equatable {
    var title: String?
    var lastActivity: Date?
    var lastFocused: Date?
    var archived: Bool
}

/// Reads the Claude app's session records (~/Library/Application Support/Claude/claude-code-sessions)
/// for the sessions that are running, so Watcher can name them and know when they were really last used.
final class ClaudeSessionStore {
    let root: String
    private var paths: [String: String] = [:]
    private var cache: [String: (mtime: Date, record: ClaudeSessionRecord)] = [:]
    private var lastIndex = Date.distantPast

    init(root: String = NSHomeDirectory() + "/Library/Application Support/Claude/claude-code-sessions") {
        self.root = root
    }

    func records(for ids: Set<String>, now: Date = Date()) -> [String: ClaudeSessionRecord] {
        if ids.contains(where: { paths[$0] == nil }), now.timeIntervalSince(lastIndex) > 300 {
            index()
            lastIndex = now
        }
        var out: [String: ClaudeSessionRecord] = [:]
        for id in ids {
            guard let path = paths[id] else { continue }
            // Parse only when the file changed (a stat is far cheaper than reading the JSON).
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            if let c = cache[id], c.mtime == mtime { out[id] = c.record; continue }
            guard let r = Self.read(path) else { continue }
            cache[id] = (mtime, r)
            out[id] = r
        }
        cache = cache.filter { ids.contains($0.key) }
        return out
    }

    /// root/<account>/<org>/local_<id>.json
    private func index() {
        let fm = FileManager.default
        for a in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            for b in (try? fm.contentsOfDirectory(atPath: root + "/" + a)) ?? [] {
                let dir = root + "/" + a + "/" + b
                for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasPrefix("local_") && f.hasSuffix(".json") {
                    paths[String(f.dropLast(5))] = dir + "/" + f
                }
            }
        }
    }

    static func read(_ path: String) -> ClaudeSessionRecord? {
        guard let data = FileManager.default.contents(atPath: path),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func date(_ k: String) -> Date? { (d[k] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
        let title = (d["title"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return ClaudeSessionRecord(title: title, lastActivity: date("lastActivityAt"), lastFocused: date("lastFocusedAt"),
                                   archived: d["isArchived"] as? Bool ?? false)
    }
}

/// The Claude app's own link to a session (the format it reports for its sessions).
enum ClaudeLinks {
    static func url(for t: Thing) -> URL? {
        guard case .claudeSession = t.kind, let id = t.root.hostSessionID else { return nil }
        return URL(string: "claude://claude.ai/epitaxy/\(id)")
    }
}
