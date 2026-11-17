import XCTest
@testable import SlopCleaner

final class ClassifierTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let home = "/Users/x"

    func proc(_ pid: Int32, _ name: String, ppid: Int32 = 1, uid: UInt32 = 501, path: String? = nil,
              args: [String] = [], cwd: String? = nil, cpu: Double = 0) -> ProcessSnapshot {
        ProcessSnapshot(pid: pid, ppid: ppid, uid: uid, name: name, path: path ?? "/usr/bin/\(name)", args: args,
                        cwd: cwd, startTime: now.addingTimeInterval(Double(pid)), cpu: cpu, memory: 1 << 20)
    }

    func testChromeHelpersGroupUnderChrome() {
        let base = "/Applications/Google Chrome.app"
        let procs = [
            proc(680, "Google Chrome", path: base + "/Contents/MacOS/Google Chrome", cpu: 18),
            proc(816, "Google Chrome Helper", ppid: 680,
                 path: base + "/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper", cpu: 7),
            proc(900, "Google Chrome Helper (Renderer)", ppid: 680,
                 path: base + "/Contents/Frameworks/x.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", cpu: 33),
        ]
        let things = Classifier.classify(procs, home: home).things
        XCTAssertEqual(things.count, 1)
        XCTAssertEqual(things[0].title, "Google Chrome")
        XCTAssertEqual(things[0].processes.count, 3)
        XCTAssertEqual(things[0].root.pid, 680)
        XCTAssertEqual(things[0].cpu, 58, accuracy: 0.01)
    }

    func testEmulatorParsing() {
        let q = proc(41399, "qemu-system-aarch64-headless",
                     args: ["qemu-system-aarch64-headless", "-avd", "Pixel_8_API_35", "-port", "5554", "-no-window"])
        let t = Classifier.classify([q], home: home).things[0]
        XCTAssertEqual(t.kind, .androidEmulator(serial: "emulator-5554", avd: "Pixel_8_API_35"))
        XCTAssertEqual(t.title, "Pixel 8 API 35 emulator")
    }

    func testSimulatorClaimsItsProcesses() {
        let udid = "8F1C2D3E-4A5B-4C6D-8E7F-901234567890"
        let procs = [
            proc(41283, "launchd_sim", args: ["launchd_sim", "/Users/x/Library/Developer/CoreSimulator/Devices/\(udid)/data/var/run/launchd_bootstrap.plist"]),
            proc(41307, "backboardd", ppid: 41283),
            proc(41394, "MyApp", ppid: 41283, path: "/Users/x/Library/Developer/CoreSimulator/Devices/\(udid)/data/Containers/Bundle/Application/A/MyApp.app/MyApp"),
        ]
        let things = Classifier.classify(procs, simNames: [udid: "QA iPhone"], home: home).things
        XCTAssertEqual(things.count, 1)
        XCTAssertEqual(things[0].title, "QA iPhone")
        XCTAssertEqual(things[0].processes.count, 3)
    }

    func testClaudeSessionSplitsOutItsTestRun() {
        let claudePath = "/Users/x/Library/Application Support/Claude/claude-code/2.1/abc/claude.app/Contents/MacOS/claude"
        let procs = [
            proc(250, "disclaimer", path: "/Applications/Claude.app/Contents/Helpers/disclaimer"),
            proc(251, "claude", ppid: 250, path: claudePath, cwd: "/Users/x/projects/myapp/.worktrees/feature-x"),
            proc(300, "zsh", ppid: 251, path: "/bin/zsh", args: ["/bin/zsh", "-c", "python -m pytest tests/"]),
            proc(301, "Python", ppid: 300, path: "/opt/homebrew/Python.app/Contents/MacOS/Python",
                 args: ["Python", "-m", "pytest", "-q", "tests/"], cwd: "/Users/x/projects/myapp/.worktrees/feature-x/backend", cpu: 60),
            proc(302, "Python", ppid: 301, path: "/opt/homebrew/Python.app/Contents/MacOS/Python",
                 args: ["Python", "-c", "worker"], cpu: 60),
        ]
        let things = Classifier.classify(procs, home: home).things
        let session = things.first { $0.kind == .claudeSession }!
        let test = things.first { $0.kind == .testRun }!
        XCTAssertEqual(session.subtitle, "Claude Code · feature-x worktree")
        XCTAssertEqual(Set(session.processes.map(\.pid)), [250, 251, 300])
        XCTAssertEqual(session.root.pid, 251)
        XCTAssertEqual(test.title, "pytest run")
        XCTAssertEqual(Set(test.processes.map(\.pid)), [301, 302])
        XCTAssertEqual(test.ownerLabel, "Started by the Claude session in feature-x worktree")
    }

    func testExpoServerDetected() {
        let p = proc(41231, "node", path: "/opt/homebrew/bin/node",
                     args: ["node", "/Users/x/projects/myapp/web/client/node_modules/.bin/expo", "start", "--port", "3000"],
                     cwd: "/Users/x/projects/myapp/web/client")
        let t = Classifier.classify([p], home: home).things[0]
        XCTAssertEqual(t.kind, .devServer)
        XCTAssertEqual(t.title, "Expo dev server")
        XCTAssertEqual(t.subtitle, "in web/client")
    }

    func testShellLinesDoNotCountAsDrivers() {
        let procs = [
            proc(1, "zsh", path: "/bin/zsh", args: ["/bin/zsh", "-c", "maestro --device emulator-5556 test flow.yaml; adb -s emulator-5554 shell"]),
            proc(2, "adb", path: "/sdk/platform-tools/adb", args: ["adb", "-L", "tcp:5037", "fork-server", "server", "--reply-fd", "4"]),
        ]
        XCTAssertTrue(Classifier.drivenDevices(procs).isEmpty)
    }

    func testRealDriversAreSeen() {
        let procs = [
            proc(1, "adb", path: "/sdk/platform-tools/adb", args: ["adb", "-s", "emulator-5556", "install", "-r", "app.apk"]),
            proc(2, "java", path: "/usr/bin/java", args: ["java", "-cp", "maestro.jar", "maestro.cli.AppKt", "--device", "8F1C2D3E-4A5B-4C6D-8E7F-901234567890", "test"]),
        ]
        XCTAssertEqual(Classifier.drivenDevices(procs), ["emulator-5556", "8F1C2D3E-4A5B-4C6D-8E7F-901234567890"])
    }

    func testFolderLabels() {
        XCTAssertEqual(Classifier.folderLabel("/Users/x/projects/myapp/.worktrees/feature-x/backend", home: home), "feature-x worktree")
        XCTAssertEqual(Classifier.folderLabel("/Users/x/projects", home: home), "~/projects")
        XCTAssertEqual(Classifier.folderLabel("/Users/x/projects/myapp/web/client", home: home), "web/client")
        XCTAssertEqual(Classifier.folderLabel("/", home: home), nil)
    }
}
