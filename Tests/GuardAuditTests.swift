import XCTest
@testable import SlopCleaner

/// Runs the Guard over every process on this Mac and writes what it would allow, for a human to read.
final class GuardAuditTests: XCTestCase {
    func testAuditEverythingRunning() throws {
        var allowed: [String] = []
        var refused = 0
        for kp in ProcessSampler.allProcs() where kp.kp_proc.p_pid > 0 {
            guard let f = Guard.facts(pid: kp.kp_proc.p_pid) else { continue }
            if Guard.refusal(f, kind: .signal) == nil {
                allowed.append("\(f.name)\t\(f.path)")
            } else {
                refused += 1
            }
            // Hard expectations, whatever is running.
            if ["WindowServer", "launchd", "loginwindow", "Finder", "Dock", "SystemUIServer", "ControlCenter", "Claude",
                "postgres", "redis-server"].contains(f.name) || f.isRegularApp || f.isFrontmost {
                XCTAssertNotNil(Guard.refusal(f, kind: .signal), f.name)
                if !f.isRegularApp || f.isFrontmost { XCTAssertNotNil(Guard.refusal(f, kind: .politeAppQuit), f.name) }
            }
            // Claude sessions used in the last 30 min are never allowed.
            if let ago = f.sessionUsedAgo, ago < 1800 { XCTAssertNotNil(Guard.refusal(f, kind: .signal), "active session") }
            if let ago = f.parentSessionUsedAgo, ago < 1800 { XCTAssertNotNil(Guard.refusal(f, kind: .signal), "active session's tool") }
        }
        let counts = Dictionary(allowed.map { ($0, 1) }, uniquingKeysWith: +).sorted { $0.value > $1.value }
        let out = counts.map { "\($0.value)\t\($0.key)" }.joined(separator: "\n")
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("guard-audit.txt")
        try "refused \(refused), allowed \(allowed.count)\n\(out)\n".write(to: url, atomically: true, encoding: .utf8)
        print("GUARD-AUDIT \(url.path)")
    }
}
