import XCTest
@testable import SlopCleaner

/// The absolute rules: checked right before anything is stopped, on facts read at that moment.
final class GuardTests: XCTestCase {
    func facts(_ name: String, path: String, pid: Int32 = 5000, uid: UInt32 = getuid(), apple: Bool = false,
               front: Bool = false, app: Bool = false, clients: Int = 0) -> Guard.Facts {
        Guard.Facts(pid: pid, uid: uid, name: name, path: path, applePlatform: apple, isFrontmost: front,
                    isRegularApp: app, externalClients: clients)
    }

    func testCriticalThingsAreNeverStopped() {
        let critical: [Guard.Facts] = [
            facts("launchd", path: "/sbin/launchd", pid: 1, uid: 0, apple: true),
            facts("WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", uid: 88, apple: true),
            facts("WindowServer", path: "/x/WindowServer"),                       // even if it somehow looked like ours
            facts("Finder", path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", apple: true, app: true),
            facts("Dock", path: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock", apple: true),
            facts("cfprefsd", path: "/usr/sbin/cfprefsd", apple: true),
            facts("zsh", path: "/bin/zsh", apple: true),                         // your shell
            facts("Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude", app: true),
            facts("disclaimer", path: "/Applications/Claude.app/Contents/Helpers/disclaimer"),
            facts("SomeAgent", path: "/Library/Apple/System/Library/SomeAgent", apple: true),
            facts("helperd", path: "/opt/vendor/helperd", apple: true),          // Apple-signed, not a user tool
            facts("postgres", path: "/opt/homebrew/Cellar/postgresql@17/17.11_1/bin/postgres"),
            facts("redis-server", path: "/opt/homebrew/bin/redis-server"),
        ]
        for f in critical {
            XCTAssertNotNil(Guard.refusal(f, kind: .signal), "\(f.name) must be refused")
            XCTAssertNotNil(Guard.refusal(f, kind: .politeAppQuit), "\(f.name) must be refused even politely")
        }
    }

    func testAnythingInUseIsNeverStopped() {
        XCTAssertNotNil(Guard.refusal(facts("node", path: "/opt/homebrew/bin/node", clients: 1), kind: .signal))
        XCTAssertNotNil(Guard.refusal(facts("Notes", path: "/System/Applications/Notes.app/Contents/MacOS/Notes",
                                            apple: true, front: true, app: true), kind: .politeAppQuit))
        XCTAssertNotNil(Guard.refusal(facts("x", path: "/opt/x", pid: getpid()), kind: .signal), "never itself")
        var session = facts("claude", path: "/Users/x/Library/Application Support/Claude/claude-code/a/claude.app/Contents/MacOS/claude")
        session.sessionUsedAgo = 10 * 60
        XCTAssertNotNil(Guard.refusal(session, kind: .signal), "a session used 10 min ago")
        session.sessionUsedAgo = 30 * 3600
        XCTAssertNil(Guard.refusal(session, kind: .signal), "a session idle for 30 h")
    }

    func testPartsOfAppsAreNeverForceStopped() {
        XCTAssertNotNil(Guard.refusal(facts("Google Chrome Helper (Renderer)",
            path: "/Applications/Google Chrome.app/Contents/Frameworks/x.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"),
            kind: .signal), "a browser tab")
        var codexNode = facts("node", path: "/Users/x/Library/Application Support/Codex/runtime/node")
        codexNode.ownerApp = "ChatGPT"
        XCTAssertNotNil(Guard.refusal(codexNode, kind: .signal), "an app's own background work")
        var mine = facts("node", path: "/opt/homebrew/bin/node")
        mine.ownerApp = "Ghostty"
        XCTAssertNil(Guard.refusal(mine, kind: .signal), "something you started in your terminal")
        var sessionTool = facts("Python", path: "/opt/homebrew/bin/python3")
        sessionTool.ownerApp = "Claude"
        sessionTool.parentSessionUsedAgo = 26 * 3600
        XCTAssertNil(Guard.refusal(sessionTool, kind: .signal), "a tool of a session idle for a day")
        sessionTool.parentSessionUsedAgo = 5 * 60
        XCTAssertNotNil(Guard.refusal(sessionTool, kind: .signal), "a tool (or MCP server) of a session in use")
    }

    func testAppsAreOnlyEverAskedToQuit() {
        let ghostty = facts("ghostty", path: "/Applications/Ghostty.app/Contents/MacOS/ghostty", app: true)
        XCTAssertNotNil(Guard.refusal(ghostty, kind: .signal), "never a forced stop for an app")
        XCTAssertNil(Guard.refusal(ghostty, kind: .politeAppQuit), "a polite ⌘Q is fine (it asks about running jobs)")
    }

    func testOrdinaryThingsAreAllowed() {
        XCTAssertNil(Guard.refusal(facts("node", path: "/opt/homebrew/bin/node"), kind: .signal))
        XCTAssertNil(Guard.refusal(facts("yes", path: "/usr/bin/yes", apple: true), kind: .signal), "an Apple tool you ran")
        XCTAssertNil(Guard.refusal(facts("claude", path: "/Users/x/Library/Application Support/Claude/claude-code/2.1/a/claude.app/Contents/MacOS/claude"), kind: .signal))
        XCTAssertNil(Guard.refusal(facts("Notes", path: "/System/Applications/Notes.app/Contents/MacOS/Notes", apple: true, app: true),
                                   kind: .politeAppQuit), "Apple apps: a polite ⌘Q only")
        XCTAssertNotNil(Guard.refusal(facts("Notes", path: "/System/Applications/Notes.app/Contents/MacOS/Notes", apple: true, app: true),
                                      kind: .signal), "never a signal to an Apple app")
    }

    // MARK: - Live, on this Mac

    func testLiveSystemProcessesAreRefused() throws {
        XCTAssertNotNil(Guard.refusal(try XCTUnwrap(Guard.facts(pid: 1)), kind: .signal), "launchd")
        for name in ["WindowServer", "Finder", "Dock", "loginwindow"] {
            guard let pid = pidOf(name) else { continue }
            let f = try XCTUnwrap(Guard.facts(pid: pid))
            XCTAssertNotNil(Guard.refusal(f, kind: .signal), name)
            XCTAssertNotNil(Guard.refusal(f, kind: .politeAppQuit), name)
        }
        XCTAssertNotNil(Guard.refusal(try XCTUnwrap(Guard.facts(pid: getpid())), kind: .signal), "itself")
    }

    func testLiveUserToolIsAllowedAndConnectedServerIsRefused() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate() }
        let f = try XCTUnwrap(Guard.facts(pid: sleeper.processIdentifier))
        XCTAssertNil(Guard.refusal(f, kind: .signal), "a plain tool you started: \(String(describing: Guard.refusal(f, kind: .signal)))")

        // A tiny server with something connected to it.
        let port = UInt16.random(in: 40000...60000)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        server.arguments = ["-l", "127.0.0.1", String(port)]
        server.standardOutput = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(Guard.externalClients(of: server.processIdentifier), 0, "listening, nobody connected yet")
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(rc, 0)
        Thread.sleep(forTimeInterval: 0.3)
        let g = try XCTUnwrap(Guard.facts(pid: server.processIdentifier))
        XCTAssertEqual(g.externalClients, 1)
        XCTAssertNotNil(Guard.refusal(g, kind: .signal), "something is connected: must refuse")
    }

    private func pidOf(_ name: String) -> Int32? {
        ProcessSampler.allProcs().first { kp in
            var buf = [CChar](repeating: 0, count: 4096)
            let n = proc_pidpath(kp.kp_proc.p_pid, &buf, 4096)
            return n > 0 && (String(cString: buf) as NSString).lastPathComponent == name
        }?.kp_proc.p_pid
    }
}
