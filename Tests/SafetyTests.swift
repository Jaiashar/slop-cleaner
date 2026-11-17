import XCTest
@testable import SlopCleaner

/// The checks that keep Watcher from suggesting (or doing) anything that would break what's running.
final class SafetyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let home = "/Users/x"

    func proc(_ pid: Int32, _ name: String, ppid: Int32 = 1, uid: UInt32 = 501, path: String? = nil,
              args: [String] = [], cwd: String? = nil, cpu: Double = 0, mem: UInt64 = 1 << 30, ageHours: Double = 200) -> ProcessSnapshot {
        ProcessSnapshot(pid: pid, ppid: ppid, uid: uid, name: name, path: path ?? "/usr/bin/\(name)", args: args, cwd: cwd,
                        startTime: now.addingTimeInterval(-ageHours * 3600 + Double(pid)), cpu: cpu, memory: mem)
    }

    func ctx(_ things: [Thing], _ h: History, front: Int32? = nil) -> RuleContext {
        RuleContext(things: things, stats: SystemStats(), history: h, now: now, thresholds: .make(.normal),
                    driven: [], locks: { _ in nil }, frontmostPID: front, selfPID: 99999)
    }

    func expo(clients: [String]) -> Thing {
        var t = Classifier.classify([proc(41231, "node", args: ["node", "/x/node_modules/.bin/expo", "start", "--port", "3000"],
                                          cwd: "/Users/x/projects/myapp/web/client")], home: home).things[0]
        t.listenPorts = [3000]
        t.clients = clients
        return t
    }

    // Real case: a dev server was 8 days old, but an app in a simulator was still connected to it.
    func testServerWithAClientIsNeverSuggested() {
        let t = expo(clients: ["MyApp in QA iPhone"])
        let h = History()
        h.seed(id: t.id, cpu: 30, minutes: 20, endingAt: now)
        let c = ctx([t], h)
        let i = Rules.insights(c)[t.id]!
        XCTAssertTrue(i.usage.inUseNow)
        XCTAssertEqual(i.safety.verdict, .blocked, "in use = hard no, not even 'Quit anyway'")
        XCTAssertTrue(i.safety.reasons[0].contains("MyApp in QA iPhone"))
        XCTAssertTrue(Rules.evaluate(c).isEmpty)
        XCTAssertFalse(Automation.eligible(i, idleLimit: 0))
    }

    func testUnusedOldServerIsSuggestedWithHonestWording() {
        let t = expo(clients: [])
        let h = History()
        h.seed(id: t.id, cpu: 0, minutes: 20, endingAt: now)
        let c = ctx([t], h)
        let s = Rules.evaluate(c)
        XCTAssertEqual(s.count, 1)
        XCTAssertTrue(s[0].detail.contains("No clients since Slop Cleaner started 20 min ago"), s[0].detail)
        let i = Rules.insights(c)[t.id]!
        XCTAssertFalse(i.usage.exact, "never seen used: only a lower bound")
        XCTAssertTrue(Automation.eligible(i, idleLimit: 15 * 60))
        XCTAssertFalse(Automation.eligible(i, idleLimit: 3600), "hasn't been watched long enough to know")
    }

    func testClaudeAppIsNeverQuit() {
        let app = Classifier.classify([proc(41494, "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude")], home: home).things[0]
        let i = Rules.insights(ctx([app], History()))[app.id]!
        XCTAssertEqual(i.safety.verdict, .blocked)
        XCTAssertEqual(i.safety.action, SuggestedAction.none)
    }

    func session(idleHours: Double?, pid: Int32 = 251) -> Thing {
        var t = Classifier.classify([proc(pid, "claude", path: "/Users/x/Library/Application Support/Claude/claude-code/2.1/a/claude.app/Contents/MacOS/claude",
                                         cwd: "/Users/x/projects", mem: 900 << 20)], home: home).things[0]
        t.externalLastUse = idleHours.map { now.addingTimeInterval(-$0 * 3600) }
        return t
    }

    func testSessionsAreOnlyStoppedWhenTrulyIdle() {
        let h = History()
        func verdict(_ t: Thing) -> Safety { Rules.insights(ctx([t], h))[t.id]!.safety }
        XCTAssertEqual(verdict(session(idleHours: nil)).verdict, .blocked, "no record: can't know")
        XCTAssertEqual(verdict(session(idleHours: 0)).verdict, .blocked, "working right now")
        XCTAssertEqual(verdict(session(idleHours: 0.2)).verdict, .blocked, "used 12 min ago: may be mid-task")
        XCTAssertEqual(verdict(session(idleHours: 3)).verdict, .caution, "used 3 h ago: ask first")
        let idle = verdict(session(idleHours: 30))
        XCTAssertEqual(idle.verdict, .safe)
        if case .stopSession(let pid, _) = idle.action { XCTAssertEqual(pid, 251) } else { XCTFail("wrong action") }
    }

    func testBusySessionProcessIsLeftAlone() {
        let t = session(idleHours: 30)
        let h = History()
        h.markBusy(t.id, at: now.addingTimeInterval(-30))
        XCTAssertEqual(Rules.insights(ctx([t], h))[t.id]!.safety.verdict, .blocked)
    }

    func testIdleSessionsBecomeOneSweep() {
        let sessions = (0..<6).map { session(idleHours: 30 + Double($0), pid: Int32(300 + $0)) } + [session(idleHours: 0.1, pid: 400)]
        let s = Rules.evaluate(ctx(sessions, History())).first { $0.id == "claude-pile" }!
        guard case .sweep(let ids) = s.action else { return XCTFail("not a sweep") }
        XCTAssertEqual(ids.count, 6, "the one used 6 min ago is not in it")
        XCTAssertFalse(ids.contains(sessions[6].id))
        XCTAssertEqual(s.items.count, 6)
    }

    func testLeftoverAgentToolIsSuggested() {
        let t = Classifier.classify([proc(9000, "node", ppid: 1, args: ["node", "/x/@playwright/mcp/cli.js", "--headless"], mem: 300 << 20, ageHours: 5)],
                                    home: home).things[0]
        let h = History()
        h.seed(id: t.id, cpu: 0, minutes: 12, endingAt: now)
        let s = Rules.evaluate(ctx([t], h))
        XCTAssertEqual(s.first?.id, "leftover:node")
        XCTAssertFalse(s.first?.notify ?? true)
    }

    func testAppInFrontOrJustUsedNeedsCaution() {
        let app = Classifier.classify([proc(695, "ChatGPT", path: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT")], home: home).things[0]
        let h = History()
        XCTAssertEqual(Rules.insights(ctx([app], h, front: 695))[app.id]?.usage.text, "In use now")
        XCTAssertEqual(Rules.insights(ctx([app], h, front: 695))[app.id]?.safety.verdict, .blocked)
        h.markFront(app.id, at: now.addingTimeInterval(-300))
        let i = Rules.insights(ctx([app], h))[app.id]!
        XCTAssertEqual(i.usage.text, "Last used 5 min ago")
        XCTAssertEqual(i.safety.verdict, .caution)
    }

    func testToolOfABusyClaudeSessionIsLeftAlone() {
        let claudePath = "/Users/x/Library/Application Support/Claude/claude-code/2.1/a/claude.app/Contents/MacOS/claude"
        let things = Classifier.classify([
            proc(251, "claude", path: claudePath, cwd: "/Users/x/projects"),
            proc(300, "node", ppid: 251, args: ["node", "vite"], cwd: "/Users/x/projects/myapp/site", ageHours: 100),
        ], home: home).things
        let session = things.first { $0.kind == .claudeSession }!
        let vite = things.first { $0.kind == .devServer }!
        let h = History()
        h.seed(id: vite.id, cpu: 0, minutes: 30, endingAt: now)
        h.markBusy(session.id, at: now.addingTimeInterval(-60))
        let i = Rules.insights(ctx(things, h))[vite.id]!
        XCTAssertEqual(i.safety.verdict, .blocked)
        XCTAssertTrue(Rules.evaluate(ctx(things, h)).filter { $0.thingID == vite.id }.isEmpty)
    }

    func testOriginFromTerminal() {
        let things = Classifier.classify([
            proc(934, "Ghostty", path: "/Applications/Ghostty.app/Contents/MacOS/Ghostty", ageHours: 300),
            proc(936, "login", ppid: 934, uid: 0, path: "/usr/bin/login", ageHours: 300),
            proc(937, "-zsh", ppid: 936, path: "/bin/zsh", args: ["-zsh"], ageHours: 300),
            proc(41862, "make", ppid: 937, args: ["make", "dev"]),
            proc(41863, "bash", ppid: 41862, path: "/bin/bash", args: ["/bin/bash", "-c", "cd backend && uvicorn"]),
            proc(41871, "Python", ppid: 41863, path: "/opt/Python.app/Contents/MacOS/Python",
                 args: ["Python", "-m", "uvicorn", "main:app"], cwd: "/Users/x/projects/myapp/api"),
        ], home: home).things
        let server = things.first { $0.kind == .devServer }!
        XCTAssertEqual(server.title, "Uvicorn server")
        XCTAssertEqual(server.origin, "Started from your terminal (Ghostty): make dev")
    }

    func testMakeInsideXcodeIsNotXcode() {
        let things = Classifier.classify([
            proc(934, "Ghostty", path: "/Applications/Ghostty.app/Contents/MacOS/Ghostty", ageHours: 300),
            proc(937, "-zsh", ppid: 934, path: "/bin/zsh", args: ["-zsh"], ageHours: 300),
            proc(41862, "make", ppid: 937, path: "/Applications/Xcode.app/Contents/Developer/usr/bin/make", args: ["make", "dev"]),
            proc(41871, "Python", ppid: 41862, path: "/opt/Python.app/Contents/MacOS/Python", args: ["Python", "-m", "uvicorn", "main:app"]),
        ], home: home).things
        XCTAssertNil(things.first { $0.title == "Xcode" })
        XCTAssertEqual(things.first { $0.kind == .devServer }?.origin, "Started from your terminal (Ghostty): make dev")
    }

    func testSimulatorLogStreamIsNotDriving() {
        let udid = "8F1C2D3E-4A5B-4C6D-8E7F-901234567890"
        let procs = [
            proc(41494, "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude"),
            proc(31446, "disclaimer", ppid: 41494, path: "/Applications/Claude.app/Contents/Helpers/disclaimer"),
            proc(31451, "simctl", ppid: 31446, path: "/Library/Developer/CoreSimulator/bin/simctl",
                 args: ["simctl", "spawn", udid, "log", "stream", "--style", "compact"]),
            proc(41283, "launchd_sim", args: ["launchd_sim", "/x/Devices/\(udid)/data/var/run/launchd_bootstrap.plist"]),
        ]
        let c = Classifier.classify(procs, home: home)
        XCTAssertTrue(c.driven.isEmpty)
        XCTAssertEqual(c.things.first { $0.id == "sim:\(udid)" }?.origin, "The Claude app's simulator panel is attached to it")
    }

    func testSocketClientMatching() {
        typealias S = SocketScanner.Socket
        let sockets = [
            S(pid: 41231, localPort: 3000, remotePort: 0, listening: true, established: false, remoteAddress: "::"),
            S(pid: 41231, localPort: 3000, remotePort: 52611, listening: false, established: true, remoteAddress: "::1"),
            S(pid: 41394, localPort: 52611, remotePort: 3000, listening: false, established: true, remoteAddress: "::1"),
            S(pid: 41231, localPort: 3000, remotePort: 61000, listening: false, established: true, remoteAddress: "192.168.1.20"),
            S(pid: 500, localPort: 443, remotePort: 51000, listening: false, established: true, remoteAddress: "1.2.3.4"),
        ]
        let r = SocketScanner.clients(of: sockets)
        XCTAssertEqual(r.listen[41231], [3000])
        XCTAssertEqual(Set(r.clients[41231] ?? []), [
            .init(pid: 41394, remote: nil, port: 3000),
            .init(pid: nil, remote: "192.168.1.20", port: 3000),
        ])
        XCTAssertNil(r.clients[500], "an outgoing connection isn't a client")
    }

    func testDurationsAreExact() {
        XCTAssertEqual(Format.duration((7 * 24 + 23) * 3600), "7 days 23 h")
        XCTAssertEqual(Format.duration(2 * 3600 + 15 * 60), "2 h 15 min")
        XCTAssertEqual(Format.ago(30), "just now")
    }
}

/// Your apps (Spotify, a browser, an editor…) are never closed by Automate or Sweep.
final class AppsAreLeftAloneTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func spotify(cpu: Double) -> Thing {
        let p = ProcessSnapshot(pid: 1111, ppid: 1, uid: getuid(), name: "Spotify",
                                path: "/Applications/Spotify.app/Contents/MacOS/Spotify", args: [], cwd: nil,
                                startTime: now.addingTimeInterval(-9 * 86400), cpu: cpu, memory: 700 << 20)
        return Classifier.classify([p]).things[0]
    }

    func ctx(_ t: Thing, _ h: History) -> RuleContext {
        RuleContext(things: [t], stats: SystemStats(), history: h, now: now, thresholds: .make(.normal),
                    driven: [], locks: { _ in nil }, frontmostPID: nil, selfPID: 99999)
    }

    func testAnAppIsNeverAnAutomateTarget() {
        let t = spotify(cpu: 0)
        XCTAssertEqual(t.kind, .app(bundlePath: "/Applications/Spotify.app"))
        XCTAssertNil(AutoCategory.of(t), "Automate has no category for apps, so it can never close one")
    }

    func testAnIdleAppIsNeverSuggested() {
        let t = spotify(cpu: 1)
        let h = History()
        h.seed(id: t.id, cpu: 1, minutes: 25, endingAt: now)
        XCTAssertTrue(Rules.evaluate(ctx(t, h)).isEmpty, "open for 9 days and unused is fine: apps are yours")
    }

    func testAStuckAppGetsACardButSweepNeverIncludesIt() {
        let t = spotify(cpu: 100)
        let h = History()
        h.seed(id: t.id, cpu: 100, minutes: 16, endingAt: now)
        let s = Rules.evaluate(ctx(t, h))
        XCTAssertEqual(s.count, 1)
        if case .quitApp = s[0].action {} else { XCTFail("only a polite ⌘Q, from its own button") }
        XCTAssertTrue(AppState.sweepTargets(s).isEmpty, "Sweep never quits an app")
    }
}
