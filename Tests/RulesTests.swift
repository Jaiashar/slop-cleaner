import XCTest
@testable import SlopCleaner

final class RulesTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func proc(_ pid: Int32, _ name: String, ppid: Int32 = 1, uid: UInt32 = 501, path: String? = nil,
              args: [String] = [], cwd: String? = nil, cpu: Double = 0, mem: UInt64 = 0, ageHours: Double = 1) -> ProcessSnapshot {
        ProcessSnapshot(pid: pid, ppid: ppid, uid: uid, name: name, path: path ?? "/usr/bin/\(name)", args: args,
                        cwd: cwd, startTime: now.addingTimeInterval(-ageHours * 3600 - Double(pid)), cpu: cpu, memory: mem)
    }

    func emulator(cpu: Double = 1100, ageHours: Double = 44) -> Thing {
        let q = proc(41399, "qemu-system-aarch64-headless",
                     args: ["qemu-system-aarch64-headless", "-avd", "Pixel_8_API_35", "-port", "5554"],
                     cpu: cpu, mem: 4 << 30, ageHours: ageHours)
        return Classifier.classify([q]).things[0]
    }

    func context(_ things: [Thing], history: History, driven: Set<String> = [], lock: QALock? = nil,
                 sensitivity: Sensitivity = .normal, stats: SystemStats = SystemStats()) -> RuleContext {
        RuleContext(things: things, stats: stats, history: history, now: now, thresholds: .make(sensitivity),
                    driven: driven, locks: { _ in lock }, frontmostPID: nil, selfPID: 99999)
    }

    func testIdleHotEmulatorIsSuggested() {
        let t = emulator()
        let h = History()
        h.seed(id: t.id, cpu: 1100, minutes: 10.5, endingAt: now)
        let s = Rules.evaluate(context([t], history: h))
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].id, "idle-emulator:Pixel_8_API_35")
        XCTAssertEqual(s[0].action, .stopEmulator(serial: "emulator-5554"))
        XCTAssertEqual(s[0].severity, .urgent)
        XCTAssertTrue(s[0].notify)
        XCTAssertEqual(s[0].title, "Pixel 8 API 35 emulator is using 11 cores")
    }

    func testDrivenEmulatorIsLeftAlone() {
        let t = emulator()
        let h = History()
        h.seed(id: t.id, cpu: 1100, minutes: 11, endingAt: now)
        XCTAssertTrue(Rules.evaluate(context([t], history: h, driven: ["emulator-5554"])).isEmpty)
        XCTAssertTrue(Rules.evaluate(context([t], history: h, driven: ["*android"])).isEmpty)
    }

    func testRecentlyDrivenEmulatorIsLeftAlone() {
        let t = emulator()
        let h = History()
        h.seed(id: t.id, cpu: 1100, minutes: 11, endingAt: now)
        h.markDriven("emulator-5554", at: now.addingTimeInterval(-120))
        XCTAssertTrue(Rules.evaluate(context([t], history: h)).isEmpty)
    }

    func testLockedEmulatorHasNoButton() {
        let t = emulator()
        let h = History()
        h.seed(id: t.id, cpu: 1100, minutes: 11, endingAt: now)
        let lock = QALock(holder: "calendar-qa: month view", since: now, stale: false)
        let s = Rules.evaluate(context([t], history: h, lock: lock))
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].blockedNote, "Reserved by calendar-qa: month view")
    }

    func testStaleLockDoesNotBlock() {
        let t = emulator()
        let h = History()
        h.seed(id: t.id, cpu: 1100, minutes: 11, endingAt: now)
        let lock = QALock(holder: "old session", since: now.addingTimeInterval(-7200), stale: true)
        XCTAssertNil(Rules.evaluate(context([t], history: h, lock: lock))[0].blockedNote)
    }

    /// Real case (11/22): an emulator idled 14 h at ~7 cores and was never suggested, because adb's background
    /// server (always connected to every emulator) counted as "someone connected to it right now".
    func emulatorWithConnections(extraClient: ProcessSnapshot? = nil) -> Thing {
        let q = proc(41399, "qemu-system-aarch64-headless",
                     args: ["qemu-system-aarch64-headless", "-avd", "Pixel_8_API_35", "-port", "5554", "-no-window"],
                     cpu: 730, mem: 6 << 30, ageHours: 14)
        let adbServer = proc(13024, "adb", path: "/sdk/platform-tools/adb",
                             args: ["adb", "-L", "tcp:5037", "fork-server", "server", "--reply-fd", "4"], ageHours: 300)
        var procs = [q, adbServer]
        if let e = extraClient { procs.append(e) }
        var things = Classifier.classify(procs).things
        typealias S = SocketScanner.Socket
        var sockets = [
            S(pid: 41399, localPort: 5555, remotePort: 0, listening: true, established: false, remoteAddress: "127.0.0.1"),
            S(pid: 41399, localPort: 5555, remotePort: 58314, listening: false, established: true, remoteAddress: "127.0.0.1"),
            S(pid: 13024, localPort: 58314, remotePort: 5555, listening: false, established: true, remoteAddress: "127.0.0.1"),
        ]
        if let e = extraClient {
            sockets += [
                S(pid: 41399, localPort: 8554, remotePort: 0, listening: true, established: false, remoteAddress: "::1"),
                S(pid: 41399, localPort: 8554, remotePort: 60001, listening: false, established: true, remoteAddress: "::1"),
                S(pid: e.pid, localPort: 60001, remotePort: 8554, listening: false, established: true, remoteAddress: "::1"),
            ]
        }
        let found = SocketScanner.clients(of: sockets)
        Engine.attachConnections(&things, procs: procs, listen: found.listen, clients: found.clients, selfPID: 99999)
        return things.first { $0.id == "emu:emulator-5554" }!
    }

    func testAdbServerConnectionIsNotUse() {
        let t = emulatorWithConnections()
        XCTAssertEqual(t.clients, [], "adb's server is plumbing, not a user")
        XCTAssertEqual(t.listenPorts, [5555])
        let h = History()
        h.seed(id: t.id, cpu: 730, minutes: 11, endingAt: now)
        h.markDriven("emulator-5554", at: now.addingTimeInterval(-6 * 3600))
        let c = context([t], history: h)
        let s = Rules.evaluate(c)
        XCTAssertEqual(s.map(\.id), ["idle-emulator:Pixel_8_API_35"])
        XCTAssertEqual(s[0].action, .stopEmulator(serial: "emulator-5554"))
        let i = Rules.insights(c)[t.id]!
        XCTAssertEqual(i.safety.verdict, .safe, i.safety.reasons.joined(separator: " "))
        XCTAssertTrue(Automation.eligible(i, idleLimit: 2 * 3600), "6 h undriven, past a 2 h limit")
    }

    func testARealClientStillBlocksAnEmulator() {
        // Android Studio's Running Devices panel streams the screen over the emulator's gRPC port.
        let studio = proc(7001, "studio", path: "/Applications/Android Studio.app/Contents/MacOS/studio", ageHours: 5)
        let t = emulatorWithConnections(extraClient: studio)
        XCTAssertEqual(t.clients, ["Android Studio"])
        let h = History()
        h.seed(id: t.id, cpu: 730, minutes: 11, endingAt: now)
        let c = context([t], history: h)
        XCTAssertTrue(Rules.evaluate(c).isEmpty)
        XCTAssertEqual(Rules.insights(c)[t.id]!.safety.verdict, .blocked)
    }

    func testBusyEmulatorRightAfterARestartIsNotCalledIdle() {
        let t = emulatorWithConnections()          // 7.3 cores right now, up 14 h
        let h = History()
        h.seed(id: t.id, cpu: 730, minutes: 1, endingAt: now)   // Slop Cleaner restarted a minute ago
        h.markDriven("emulator-5554", at: now.addingTimeInterval(-6 * 3600))
        let s = Rules.evaluate(context([t], history: h))
        XCTAssertEqual(s.count, 1)
        XCTAssertFalse(s[0].detail.contains("isn't using much CPU"), s[0].detail)
        XCTAssertTrue(s[0].detail.hasPrefix("Running ") && s[0].detail.contains(". Last driven 6 h ago."), s[0].detail)
        XCTAssertEqual(s[0].severity, .suggest)
    }

    func testNotEnoughHistoryMeansNoVerdict() {
        let t = emulator(ageHours: 1)
        let h = History()
        h.seed(id: t.id, cpu: 1100, minutes: 3, endingAt: now)
        XCTAssertTrue(Rules.evaluate(context([t], history: h)).isEmpty)
    }

    func testRunawayProcessAndProtectedNames() {
        let busy = Thing(id: "proc:1", kind: .process, title: "yes", subtitle: "pid 1",
                         processes: [proc(4242, "yes", cpu: 100)])
        let ws = Thing(id: "sys:2", kind: .system, title: "WindowServer", subtitle: "System",
                       processes: [proc(418, "WindowServer", uid: 88, cpu: 300)])
        let h = History()
        h.seed(id: busy.id, cpu: 100, minutes: 16, endingAt: now)
        h.seed(id: ws.id, cpu: 300, minutes: 16, endingAt: now)
        let s = Rules.evaluate(context([busy, ws], history: h))
        XCTAssertEqual(s.map(\.id), ["runaway:yes"])
        if case .terminate(let pid, _) = s[0].action { XCTAssertEqual(pid, 4242) } else { XCTFail("wrong action") }
        // Busy is the problem here, not a sign that someone is using it.
        let i = Rules.insights(context([busy, ws], history: h))[busy.id]!
        XCTAssertFalse(i.usage.inUseNow)
        XCTAssertEqual(i.safety.verdict, .safe)
    }

    func testRootDaemonGetsCopyCommand() {
        let d = Thing(id: "sys:3", kind: .system, title: "PerfPowerServices", subtitle: "System",
                      processes: [proc(500, "PerfPowerServices", uid: 0, cpu: 200)])
        let h = History()
        h.seed(id: d.id, cpu: 200, minutes: 16, endingAt: now)
        let s = Rules.evaluate(context([d], history: h))
        XCTAssertEqual(s.first?.action, .copyCommand("sudo killall PerfPowerServices"))
    }

    func testSwapAloneIsNotAProblem() {
        var stats = SystemStats()
        stats.swapUsed = 9 << 30
        XCTAssertTrue(Rules.evaluate(context([], history: History(), stats: stats)).isEmpty,
                      "a few GB of swap at normal pressure is normal on a Mac")
        stats.pressureLevel = 2
        let s = Rules.evaluate(context([], history: History(), stats: stats))
        XCTAssertEqual(s.map(\.id), ["memory"])
        XCTAssertTrue(s[0].notify)
    }

    // MARK: - Notification gate

    func sample(_ severity: Severity = .suggest) -> Suggestion {
        Suggestion(id: "x", thingID: nil, severity: severity, symbol: "cpu", title: "t", detail: "d", evidence: [],
                   action: .none, actionTitle: "", notify: true, ignoreLabel: "x")
    }

    func testCooldownSnoozeIgnoreQuietHours() {
        let s = sample()
        XCTAssertTrue(NotificationGate.shouldNotify(s, now: now, lastNotified: nil, snoozedUntil: nil, ignored: false, enabled: true, quiet: nil))
        XCTAssertFalse(NotificationGate.shouldNotify(s, now: now, lastNotified: now.addingTimeInterval(-3600), snoozedUntil: nil, ignored: false, enabled: true, quiet: nil))
        XCTAssertTrue(NotificationGate.shouldNotify(s, now: now, lastNotified: now.addingTimeInterval(-3 * 3600), snoozedUntil: nil, ignored: false, enabled: true, quiet: nil))
        XCTAssertFalse(NotificationGate.shouldNotify(sample(.info), now: now, lastNotified: now.addingTimeInterval(-3 * 3600), snoozedUntil: nil, ignored: false, enabled: true, quiet: nil))
        XCTAssertFalse(NotificationGate.shouldNotify(s, now: now, lastNotified: nil, snoozedUntil: now.addingTimeInterval(60), ignored: false, enabled: true, quiet: nil))
        XCTAssertFalse(NotificationGate.shouldNotify(s, now: now, lastNotified: nil, snoozedUntil: nil, ignored: true, enabled: true, quiet: nil))
        XCTAssertFalse(NotificationGate.shouldNotify(s, now: now, lastNotified: nil, snoozedUntil: nil, ignored: false, enabled: false, quiet: nil))
    }

    func testQuietHoursWrapMidnight() {
        let q = QuietHours(startHour: 23, endHour: 8)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: h))! }
        XCTAssertTrue(q.contains(at(23), calendar: cal))
        XCTAssertTrue(q.contains(at(3), calendar: cal))
        XCTAssertFalse(q.contains(at(8), calendar: cal))
        XCTAssertFalse(q.contains(at(14), calendar: cal))
    }
}

final class MacOSJobsAndHabitsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testBusyMacOSJobIsExplainedNeverStopped() {
        let p = ProcessSnapshot(pid: 4116, ppid: 1, uid: getuid(), name: "mediaanalysisd",
                                path: "/System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd",
                                args: [], cwd: nil, startTime: now.addingTimeInterval(-3 * 86400), cpu: 120, memory: 1 << 30)
        let t = Classifier.classify([p]).things[0]
        let h = History()
        h.seed(id: t.id, cpu: 120, minutes: 31, endingAt: now)
        let c = RuleContext(things: [t], stats: SystemStats(), history: h, now: now, thresholds: .make(.normal),
                            driven: [], locks: { _ in nil }, frontmostPID: nil, selfPID: 99999)
        let s = Rules.evaluate(c)
        XCTAssertEqual(s.map(\.id), ["macos-job:mediaanalysisd"])
        XCTAssertEqual(s[0].action, SuggestedAction.none, "explained, never stoppable")
        XCTAssertFalse(s[0].notify)
    }

    func testNewGradleDaemonIsNotARegret() {
        let p = ProcessSnapshot(pid: 900, ppid: 1, uid: getuid(), name: "java", path: "/usr/bin/java",
                                args: ["java", "org.gradle.launcher.daemon.bootstrap.GradleDaemon"], cwd: nil,
                                startTime: now, cpu: 0, memory: 1 << 30)
        let t = Classifier.classify([p]).things[0]
        let m = UsageMemory()
        let before = m.pick(for: t, recentCPU: 0, now: now).seconds
        m.markClosed(t, now: now)
        m.observe(t, inUseNow: false, now: now.addingTimeInterval(600))   // the next build started a new one
        XCTAssertEqual(m.pick(for: t, recentCPU: 0, now: now).seconds, before)
    }
}

final class HeatSourceTests: XCTestCase {
    func thing(_ kind: ThingKind, _ name: String, _ path: String, cpu: Double, owner: String? = nil, origin: String? = nil) -> Thing {
        let p = ProcessSnapshot(pid: Int32.random(in: 1000...9000), ppid: 1, uid: getuid(), name: name, path: path, args: [], cwd: nil,
                                startTime: Date(), cpu: cpu, memory: 1 << 30)
        var t = Thing(id: UUID().uuidString, kind: kind, title: name, subtitle: "", processes: [p])
        t.ownerID = owner
        t.origin = origin
        return t
    }

    func testIdleDeviceIsLeftRunningNotWork() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let q = ProcessSnapshot(pid: 41399, ppid: 1, uid: 501, name: "qemu-system-aarch64-headless", path: "/sdk/qemu",
                                args: ["qemu", "-avd", "Pixel_8_API_35", "-port", "5554"], cwd: nil,
                                startTime: now.addingTimeInterval(-14 * 3600), cpu: 730, memory: 6 << 30)
        let emu = Classifier.classify([q]).things[0]
        let daemon = thing(.buildDaemon, "Kotlin daemon", "/opt/java", cpu: 123)
        let h = History()
        h.seed(id: emu.id, cpu: 730, minutes: 11, endingAt: now)
        func rows(drivenAgo: TimeInterval) -> [HeatSource.Row] {
            h.markDriven("emulator-5554", at: now.addingTimeInterval(-drivenAgo))
            let c = RuleContext(things: [emu, daemon], stats: SystemStats(), history: h, now: now, thresholds: .make(.normal),
                                driven: [], locks: { _ in nil }, frontmostPID: nil, selfPID: 99999)
            return HeatSource.breakdown([emu, daemon], insights: Rules.insights(c)) { $0.cpu }
        }
        let idle = rows(drivenAgo: 6 * 3600)
        XCTAssertEqual(idle.map(\.source), [.leftOn, .work])
        XCTAssertEqual(idle[0].top, ["Pixel 8 API 35 emulator 7.3 cores"])
        XCTAssertEqual(rows(drivenAgo: 60).map(\.source), [.work], "driven a minute ago: still work in progress")
    }

    func testLoadIsGroupedBySource() {
        let things = [
            thing(.buildDaemon, "Kotlin daemon", "/opt/java", cpu: 123),
            thing(.process, "mediaanalysisd", "/System/Library/PrivateFrameworks/MediaAnalysis.framework/mediaanalysisd", cpu: 122),
            thing(.process, "Python", "/opt/homebrew/bin/python3", cpu: 59, owner: "claude:1"),
            thing(.system, "WindowServer", "/System/Library/WindowServer", cpu: 51),
            thing(.app(bundlePath: "/Applications/Claude.app"), "Claude", "/Applications/Claude.app/Contents/MacOS/Claude", cpu: 40),
        ]
        let rows = HeatSource.breakdown(things) { $0.cpu }
        XCTAssertEqual(rows.map { $0.source }, [HeatSource.work, HeatSource.macOS, HeatSource.apps])
        XCTAssertEqual(rows[0].cpu, 182, accuracy: 0.1)
        XCTAssertEqual(rows[0].top.first, "Kotlin daemon 1.2 cores")
        XCTAssertEqual(rows[1].top.first, "Photos analysis 1.2 cores", "macOS jobs get their plain name")
    }
}
