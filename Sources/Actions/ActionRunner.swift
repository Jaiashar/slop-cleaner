import AppKit
import Foundation

/// Carries out a suggestion's action. Every action is logged.
enum ActionRunner {
    struct Outcome {
        let ok: Bool
        let message: String
        /// An app was asked to quit (⌘Q) but is still open: it's probably asking about unsaved work, or stuck.
        var stillOpen = false
    }

    static var logURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Slop Cleaner", isDirectory: true)
        let old = support.appendingPathComponent("Watcher", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: dir)          // keep history and learned habits from before the rename
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("actions.log")
    }

    /// Runs off the main thread (adb and simctl can take a few seconds).
    static func run(_ action: SuggestedAction, id: String, title: String, label: String) async -> Outcome {
        let outcome: Outcome = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: perform(action, label: label))
            }
        }
        log("\(outcome.ok ? "OK" : "FAILED") \(id) [\(title)] \(outcome.message)")
        return outcome
    }

    private static func perform(_ action: SuggestedAction, label: String) -> Outcome {
        switch action {
        case .stopEmulator(let serial):
            guard let adb = Shell.adbPath else { return Outcome(ok: false, message: "Couldn't find adb.") }
            let r = Shell.run(adb, ["-s", serial, "emu", "kill"], timeout: 30)
            let ok = r?.status == 0
            return Outcome(ok: ok, message: ok ? "Shutting down \(label). Its snapshot is being saved."
                                               : "adb couldn't stop \(serial): \(r?.output.trimmed ?? "no answer")")

        case .shutdownSimulator(let udid):
            // A busy Mac can take a while; and what counts is the simulator's state afterwards, not simctl's exit code.
            let r = Shell.run("/usr/bin/xcrun", ["simctl", "shutdown", udid], timeout: 180)
            if simulatorState(udid) == "Shutdown" { return Outcome(ok: true, message: "Shut down \(label).") }
            let why = r.map { $0.output.trimmed.isEmpty ? "exit code \($0.status)" : $0.output.trimmed } ?? "simctl didn't start"
            return Outcome(ok: false, message: "simctl couldn't shut \(label) down (\(why)).")

        case .terminate(let pid, let start):
            return terminate(pid: pid, start: start, label: label, politeApp: false)

        case .quitApp(let pid, let start):
            return terminate(pid: pid, start: start, label: label, politeApp: true)

        case .stopSession(let pid, let start):
            let o = terminate(pid: pid, start: start, label: label, politeApp: false)
            return o.ok ? Outcome(ok: true, message: "Stopped “\(label)”. It's still in Claude and starts again when you open it.") : o

        case .sweep:
            return Outcome(ok: false, message: "A sweep runs item by item.")   // AppState handles it

        case .copyCommand(let cmd):
            DispatchQueue.main.sync {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
            }
            return Outcome(ok: true, message: "Copied “\(cmd)”. Paste it in Terminal; it asks for your password.")

        case .showApp(let pid):
            DispatchQueue.main.sync {
                _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
            }
            return Outcome(ok: true, message: "Brought \(label) to the front.")

        case .openClaude:
            let url = URL(fileURLWithPath: "/Applications/Claude.app")
            DispatchQueue.main.async { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
            return Outcome(ok: true, message: "Opened Claude.")

        case .none:
            return Outcome(ok: true, message: "")
        }
    }

    /// The only place Slop Cleaner stops a process. Order of checks:
    /// 1. the pid still means the same process (no pid reuse),
    /// 2. the Guard, with facts read right now (system, frontmost, connected clients...),
    /// 3. apps get a polite ⌘Q only, so they can ask about unsaved work; never a forced stop.
    private static func terminate(pid: Int32, start: Date, label: String, politeApp: Bool) -> Outcome {
        guard let now = ProcessSampler.startTime(of: pid), abs(now.timeIntervalSince(start)) < 0.01 else {
            return Outcome(ok: true, message: "\(label) had already stopped.")
        }
        guard let facts = Guard.facts(pid: pid) else {
            return Outcome(ok: true, message: "\(label) had already stopped.")
        }
        if let why = Guard.refusal(facts, kind: politeApp ? .politeAppQuit : .signal) {
            log("REFUSED by guard: \(facts.name) (pid \(pid)): \(why)")
            return Outcome(ok: false, message: "Left \(label) alone: \(why)")
        }
        if politeApp {
            DispatchQueue.main.sync { _ = NSRunningApplication(processIdentifier: pid)?.terminate() }
            if waitForExit(pid, start: start, seconds: 8) { return Outcome(ok: true, message: "Quit \(label).") }
            return Outcome(ok: false, message: "Asked \(label) to quit. It's still open, probably asking about unsaved work, so it's up to you.",
                           stillOpen: true)
        }
        guard kill(pid, SIGTERM) == 0 else {
            return Outcome(ok: false, message: "macOS didn't let Slop Cleaner stop \(label) (\(String(cString: strerror(errno)))).")
        }
        // Give it time to save and exit (a Claude session can take several seconds on a busy Mac).
        if waitForExit(pid, start: start, seconds: 20) { return Outcome(ok: true, message: "Stopped \(label).") }
        return Outcome(ok: false, message: "Asked \(label) to stop, but it's still running. It may be stuck; Activity Monitor can force-quit it.")
    }

    /// "Booted", "Shutdown", "Shutting Down"… from simctl, or nil if unknown.
    static func simulatorState(_ udid: String) -> String? {
        guard let out = Shell.run("/usr/bin/xcrun", ["simctl", "list", "-j", "devices"], timeout: 20)?.output,
              let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else { return nil }
        for list in devices.values {
            if let d = list.first(where: { ($0["udid"] as? String)?.uppercased() == udid.uppercased() }) { return d["state"] as? String }
        }
        return nil
    }

    private static func waitForExit(_ pid: Int32, start: Date, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard let s = ProcessSampler.startTime(of: pid), abs(s.timeIntervalSince(start)) < 0.01 else { return true }
            usleep(200_000)
        }
        return false
    }

    static func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        let url = logURL
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
