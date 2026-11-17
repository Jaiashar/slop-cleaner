import Foundation

/// Learns, for each emulator, simulator, dev server and build daemon, how *you* use it, so Automate
/// can pick a close-after time per item instead of one fixed number. Everything stays on this Mac.
///
/// It learns three things:
/// - your breaks: how long it usually sits unused before you come back to it,
/// - regrets: you brought it back soon after Watcher closed it,
/// - keeps: you pressed "Keep it running".
/// Regrets and keeps make the time longer for that item only.
final class UsageMemory {
    struct Item: Codable {
        var gaps: [Gap] = []
        var lastUse: Date?
        var closedAt: Date?
        var regrets: Int = 0
        var keeps: Int = 0
    }
    struct Gap: Codable { let at: Date; let seconds: TimeInterval }

    private(set) var items: [String: Item] = [:]
    private var savedAt = Date.distantPast

    static let minGap: TimeInterval = 5 * 60            // shorter pauses are just "still using it"
    static let regretWindow: TimeInterval = 3 * 3600    // came back within 3 h of a close = regret
    static let keepDays: TimeInterval = 30 * 86400

    /// The same emulator, simulator or server across restarts (pids change, these don't).
    static func key(for t: Thing) -> String? {
        switch t.kind {
        case .androidEmulator(_, let avd): return "emu:\(avd)"
        case .iosSimulator(let udid, _): return "sim:\(udid)"
        case .devServer: return "server:\(t.title)|\(t.subtitle)"
        case .buildDaemon: return "daemon:\(t.title)"
        case .claudeSession: return "session:\(t.root.hostSessionID ?? t.id)"
        default: return nil
        }
    }

    // MARK: - Learning

    /// Call every tick for each item Automate could close.
    func observe(_ t: Thing, inUseNow: Bool, now: Date) {
        guard let k = Self.key(for: t) else { return }
        var it = items[k] ?? Item()
        if let closed = it.closedAt {
            // It's running again after Watcher closed it.
            let back = now.timeIntervalSince(closed)
            if back < Self.regretWindow {
                it.regrets += 1
                it.gaps.append(Gap(at: now, seconds: back + (it.lastUse.map { closed.timeIntervalSince($0) } ?? 0)))
            }
            it.closedAt = nil
        }
        if inUseNow {
            if let last = it.lastUse, now.timeIntervalSince(last) >= Self.minGap {
                it.gaps.append(Gap(at: now, seconds: now.timeIntervalSince(last)))
            }
            it.lastUse = now
        }
        it.gaps = it.gaps.filter { now.timeIntervalSince($0.at) < Self.keepDays }.suffix(60)
        items[k] = it
    }

    func markClosed(_ t: Thing, now: Date = Date()) {
        guard let k = Self.key(for: t) else { return }
        items[k, default: Item()].closedAt = now
    }

    func markKept(_ t: Thing) {
        guard let k = Self.key(for: t) else { return }
        items[k, default: Item()].keeps += 1
    }

    func forget() { items = [:] }

    // MARK: - Picking the time

    struct Pick: Hashable { let seconds: TimeInterval; let reason: String; let learned: Bool }

    /// - Enough history (3+ breaks): a little longer than 9 in 10 of your breaks with it.
    /// - Not yet: by cost. Something burning cores gets 1 h, a light one 6 h.
    /// - Each regret or keep makes it 1.5x longer (up to 4x). Always between 30 min and 24 h.
    func pick(for t: Thing, recentCPU: Double, now: Date = Date()) -> Pick {
        let it = Self.key(for: t).flatMap { items[$0] } ?? Item()
        let gaps = it.gaps.filter { now.timeIntervalSince($0.at) < Self.keepDays }.map(\.seconds).sorted()

        var base: TimeInterval
        var reason: String
        var learned = false
        let isSession: Bool = { if case .claudeSession = t.kind { return true }; return false }()
        if isSession {
            // Sessions are cheap to bring back but you may return to them days later; be patient.
            if gaps.count >= 3 {
                let p90 = gaps[min(gaps.count - 1, Int((Double(gaps.count) * 0.9).rounded(.up)) - 1)]
                base = max(12 * 3600, p90 * 1.25)
                reason = "Your breaks with it are usually under \(Format.duration(p90))"
                learned = true
            } else {
                base = 24 * 3600
                reason = "Still learning your habits. Sessions get a full day"
            }
            let pushback = it.regrets + it.keeps
            if pushback > 0 { base *= min(4, pow(1.5, Double(pushback))); reason += ", plus extra because you wanted it back" }
            return Pick(seconds: (min(7 * 86400, base) / 3600).rounded(.up) * 3600, reason: reason, learned: learned)
        }
        if gaps.count >= 3 {
            let p90 = gaps[min(gaps.count - 1, Int((Double(gaps.count) * 0.9).rounded(.up)) - 1)]
            base = p90 * 1.25
            reason = "Your breaks with it are usually under \(Format.duration(p90))"
            learned = true
        } else if recentCPU >= 100 || t.memory >= 4 * 1_073_741_824 {
            base = 3600
            let heavy = recentCPU >= 100 ? "uses \(Format.cores(recentCPU))" : "holds \(Format.bytes(t.memory))"
            reason = "Still learning your habits. It \(heavy), so sooner"
        } else if recentCPU >= 20 || t.memory >= 1_073_741_824 {
            base = 3 * 3600
            reason = "Still learning your habits"
        } else {
            base = 6 * 3600
            reason = "Still learning your habits. It's light, so it can wait"
        }

        let pushback = it.regrets + it.keeps
        if pushback > 0 {
            base *= min(4, pow(1.5, Double(pushback)))
            reason += pushback == 1 ? ", plus extra because you wanted it back once" : ", plus extra because you wanted it back \(pushback) times"
        }
        let rounded = (min(24 * 3600, max(30 * 60, base)) / 900).rounded(.up) * 900   // nice 15-min steps
        return Pick(seconds: rounded, reason: reason, learned: learned)
    }

    // MARK: - Saving

    private struct Saved: Codable { var savedAt: Date; var items: [String: Item] }

    func save(to url: URL, now: Date = Date()) {
        if let data = try? JSONEncoder().encode(Saved(savedAt: now, items: items)) { try? data.write(to: url, options: .atomic) }
    }

    /// Learned habits survive restarts. Only "last used" is dropped after a long gap, because
    /// Watcher didn't see what happened while it was off and must not invent a long break.
    func load(from url: URL, now: Date = Date()) {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        items = s.items
        if now.timeIntervalSince(s.savedAt) > 10 * 60 {
            for k in items.keys { items[k]?.lastUse = nil }
        }
    }
}
