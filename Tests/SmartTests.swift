import XCTest
@testable import SlopCleaner

/// Smart timing learns per item, per person, and never shortens time after you pushed back.
final class SmartTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func emulator(mem: UInt64 = 2 << 30) -> Thing {
        let p = ProcessSnapshot(pid: 41399, ppid: 1, uid: 501, name: "qemu-system-aarch64",
                                path: "/sdk/qemu-system-aarch64", args: ["qemu", "-avd", "Pixel_8_API_35", "-port", "5554"],
                                cwd: nil, startTime: t0, cpu: 0, memory: mem)
        return Classifier.classify([p]).things[0]
    }

    func testDefaultsDependOnCost() {
        let m = UsageMemory()
        XCTAssertEqual(m.pick(for: emulator(), recentCPU: 1100, now: t0).seconds, 3600, "heavy: 1 h")
        XCTAssertEqual(m.pick(for: emulator(mem: 200 << 20), recentCPU: 2, now: t0).seconds, 6 * 3600, "light: 6 h")
        XCTAssertFalse(m.pick(for: emulator(), recentCPU: 1100, now: t0).learned)
    }

    func testLearnsYourBreaks() {
        let m = UsageMemory()
        let t = emulator()
        var now = t0
        // You use it, then come back after 40, 50, 60 and 80 minutes.
        m.observe(t, inUseNow: true, now: now)
        for gap in [40.0, 50, 60, 80] {
            now.addTimeInterval(gap * 60)
            m.observe(t, inUseNow: true, now: now)
        }
        let pick = m.pick(for: t, recentCPU: 1100, now: now)
        XCTAssertTrue(pick.learned)
        XCTAssertEqual(pick.seconds, 6300, "p90 = 80 min, x1.25 = 100 min, rounded up to 105 min")
        XCTAssertEqual(pick.reason, "Your breaks with it are usually under 1 h 20 min")
    }

    /// Real case (11/22): a QA emulator's learned breaks (33 h, 41 h) came from stretches it sat unused at
    /// 4-7 cores, so Smart waited 24 h. What it costs while it waits caps the wait.
    func testCostCapsALearnedWait() {
        let m = UsageMemory()
        let t = emulator(mem: 6 << 30)
        var now = t0
        m.observe(t, inUseNow: true, now: now)
        for gap in [38.0, 47, 2002, 770, 30, 231, 2478, 481] {
            now.addTimeInterval(gap * 60)
            m.observe(t, inUseNow: true, now: now)
        }
        let hot = m.pick(for: t, recentCPU: 730, now: now)
        XCTAssertTrue(hot.learned)
        XCTAssertEqual(hot.seconds, 2 * 3600)
        XCTAssertEqual(hot.reason, "Your breaks with it are usually under 41 h, but it uses 7.3 cores while it waits, so 2 h at most")
        XCTAssertEqual(m.pick(for: t, recentCPU: 4, now: now).seconds, 8 * 3600, "idle on a still screen but holding 6 GB")
        m.markKept(t)
        XCTAssertEqual(m.pick(for: t, recentCPU: 730, now: now).seconds, 3 * 3600, "keep it running still buys more time")
    }

    func testCheapItemKeepsItsLearnedWait() {
        let m = UsageMemory()
        let t = emulator(mem: 200 << 20)
        var now = t0
        m.observe(t, inUseNow: true, now: now)
        for gap in [600.0, 700, 800] { now.addTimeInterval(gap * 60); m.observe(t, inUseNow: true, now: now) }
        XCTAssertEqual(m.pick(for: t, recentCPU: 2, now: now).seconds, 60300, "800 min x1.25 = 16 h 40 min, in 15-min steps; light, so no cap")
    }

    func testShortPausesAreNotBreaks() {
        let m = UsageMemory()
        let t = emulator()
        var now = t0
        for _ in 0..<10 { m.observe(t, inUseNow: true, now: now); now.addTimeInterval(60) }
        XCTAssertFalse(m.pick(for: t, recentCPU: 1100, now: now).learned)
    }

    func testBringingItBackMakesItLonger() {
        let m = UsageMemory()
        let t = emulator()
        let before = m.pick(for: t, recentCPU: 1100, now: t0).seconds
        m.markClosed(t, now: t0)
        m.observe(t, inUseNow: false, now: t0.addingTimeInterval(20 * 60))   // started again 20 min later
        let after = m.pick(for: t, recentCPU: 1100, now: t0.addingTimeInterval(20 * 60))
        XCTAssertEqual(after.seconds, before * 1.5)
        XCTAssertTrue(after.reason.contains("you wanted it back once"))
        m.markKept(t)
        XCTAssertEqual(m.pick(for: t, recentCPU: 1100, now: t0).seconds, before * 2.25)
    }

    func testReturningLongAfterAClosIsNotARegret() {
        let m = UsageMemory()
        let t = emulator()
        m.markClosed(t, now: t0)
        m.observe(t, inUseNow: false, now: t0.addingTimeInterval(5 * 3600))
        XCTAssertEqual(m.pick(for: t, recentCPU: 1100, now: t0).seconds, 3600)
    }

    func testRestartAfterALongGapDoesNotInventABreak() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("habits-\(UUID()).json")
        let m = UsageMemory()
        let t = emulator()
        m.observe(t, inUseNow: true, now: t0)
        m.save(to: url, now: t0)
        let m2 = UsageMemory()
        m2.load(from: url, now: t0.addingTimeInterval(6 * 3600))   // Watcher was off for 6 h
        m2.observe(t, inUseNow: true, now: t0.addingTimeInterval(6 * 3600))
        XCTAssertTrue(m2.items.values.first?.gaps.isEmpty ?? false, "no 6 h 'break' recorded")
        try? FileManager.default.removeItem(at: url)
    }

    func testSessionsGetAFullDayUntilLearned() {
        var p = ProcessSnapshot(pid: 251, ppid: 1, uid: 501, name: "claude", path: "/x/claude-code/a/claude.app/Contents/MacOS/claude",
                                args: [], cwd: nil, startTime: t0, cpu: 0, memory: 900 << 20)
        p.hostSessionID = "local_abc"
        let t = Classifier.classify([p]).things[0]
        let pick = UsageMemory().pick(for: t, recentCPU: 0, now: t0)
        XCTAssertEqual(pick.seconds, 24 * 3600)
        XCTAssertEqual(UsageMemory.key(for: t), "session:local_abc")
    }

    func testCleanedTally() {
        let d = UserDefaults.standard
        let saved = d.dictionary(forKey: "cleaned")
        defer { d.set(saved, forKey: "cleaned") }
        d.removeObject(forKey: "cleaned")
        let prefs = Preferences()
        prefs.recordCleaned(bytes: 2 << 30, cpu: 100, now: t0)
        prefs.recordCleaned(bytes: 1 << 30, cpu: 0, now: t0)
        XCTAssertEqual(prefs.cleanedOn(t0).count, 2)
        XCTAssertEqual(prefs.cleanedOn(t0).bytes, 3 << 30)
    }

    func testSmartSettingUsesThePick() {
        var i = Insight(usage: Usage(text: "", idleFor: 0, inUseNow: false, exact: true),
                        safety: Safety(verdict: .safe, reasons: [], notes: [], effect: "", action: .none, actionTitle: ""))
        i.smart = UsageMemory.Pick(seconds: 5400, reason: "x", learned: true)
        XCTAssertEqual(Automation.limit(setting: Automation.smart, insight: i), 5400)
        XCTAssertEqual(Automation.limit(setting: 2, insight: i), 7200)
    }

    // MARK: - Claude sessions from the Claude app's own records

    func testSessionRecordGivesTitleAndRealLastUse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ccs-\(UUID())/acct/org")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"sessionId":"local_abc","title":"Fix login bug","lastActivityAt":1799852400000,"lastFocusedAt":1799850000000,"isArchived":false}"#
        try json.write(to: dir.appendingPathComponent("local_abc.json"), atomically: true, encoding: .utf8)
        let store = ClaudeSessionStore(root: dir.deletingLastPathComponent().deletingLastPathComponent().path)
        let recs = store.records(for: ["local_abc"], now: t0)
        XCTAssertEqual(recs["local_abc"]?.title, "Fix login bug")

        var p = ProcessSnapshot(pid: 251, ppid: 1, uid: 501, name: "claude",
                                path: "/x/claude-code/2.1/a/claude.app/Contents/MacOS/claude", args: [], cwd: "/Users/x/projects",
                                startTime: t0.addingTimeInterval(-90 * 3600), cpu: 0, memory: 300 << 20)
        p.hostSessionID = "local_abc"
        let things = Classifier.classify([p], sessions: recs, home: "/Users/x").things
        XCTAssertEqual(things[0].title, "Fix login bug")
        let c = RuleContext(things: things, stats: SystemStats(), history: History(), now: t0, thresholds: .make(.normal),
                            driven: [], locks: { _ in nil }, frontmostPID: nil)
        let u = Rules.insights(c)[things[0].id]!.usage
        XCTAssertEqual(u.text, "Last activity 41 h ago")
        XCTAssertTrue(u.exact)
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent())
    }
}
