import XCTest
@testable import SlopCleaner

/// Runs the real Engine over this Mac and writes, for a human to read, every device, server, session and
/// busy or big thing with what Slop Cleaner thinks of it: last used, safe or not, and why.
/// A reason that shows up on every item of a kind (e.g. "adb is connected to it right now" on every
/// emulator) is a blind spot, not a safety check. Read-only: it never saves history or acts.
final class InsightAuditTests: XCTestCase {
    func testAuditInsightsForEverythingRunning() throws {
        let engine = Engine()
        let th = Thresholds.make(.normal)
        engine.queue.sync { _ = engine.tick(thresholds: th, frontmostPID: nil, freshConnections: true) }
        Thread.sleep(forTimeInterval: 2)          // CPU is measured between two samples
        var tick: Engine.Tick!
        engine.queue.sync { tick = engine.tick(thresholds: th, frontmostPID: nil, freshConnections: true, detail: true) }

        var lines: [String] = []
        var blockedByReason: [String: Int] = [:]
        for t in tick.things {
            guard let i = tick.insights[t.id] else { continue }
            if case .system = t.kind { continue }
            let v: String = { switch i.safety.verdict { case .safe: return "SAFE"; case .caution: return "CAUTION"; case .blocked: return "BLOCKED" } }()
            var row = "\(v)\t\(t.kind.label)\t\(t.title) · \(t.subtitle)\t\(Format.cores(t.cpu))\t\(Format.bytes(t.memory))\t\(i.usage.text)"
            if !i.safety.reasons.isEmpty { row += "\n\twhy: " + i.safety.reasons.joined(separator: " | ") }
            if !t.clients.isEmpty { row += "\n\tclients: " + t.clients.joined(separator: ", ") }
            if !i.safety.notes.isEmpty { row += "\n\tnotes: " + i.safety.notes.joined(separator: " | ") }
            if let s = i.smart { row += "\n\tsmart: \(Format.duration(s.seconds)) (\(s.reason))" }
            lines.append(row)
            if i.safety.verdict == .blocked, let r = i.safety.reasons.first { blockedByReason[r, default: 0] += 1 }
        }
        let summary = blockedByReason.sorted { $0.value > $1.value }.map { "\($0.value)\t\($0.key)" }.joined(separator: "\n")
        let suggestions = tick.suggestions.map { "\($0.severity)\t\($0.title)" }.joined(separator: "\n")
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("insight-audit.txt")
        try """
        \(tick.things.count) things, \(Int(tick.stats.cpuFraction * 100))% CPU

        == Suggestions ==
        \(suggestions)

        == Blocked, by reason ==
        \(summary)

        == Everything ==
        \(lines.joined(separator: "\n"))

        """.write(to: url, atomically: true, encoding: .utf8)
        print("INSIGHT-AUDIT \(url.path)")
    }
}
