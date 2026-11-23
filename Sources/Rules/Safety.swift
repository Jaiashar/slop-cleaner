import Foundation

/// When something was last used, phrased so it's never more certain than what Watcher actually saw.
struct Usage: Hashable {
    var text: String
    /// How long it has gone unused. When Watcher never saw it used, this is how long Watcher has watched
    /// (a lower bound), and `exact` is false.
    var idleFor: TimeInterval
    var inUseNow: Bool
    var exact: Bool
}

/// Whether quitting something could cause a problem, and why.
struct Safety: Hashable {
    enum Verdict: Int { case safe, caution, blocked }
    var verdict: Verdict
    /// Reasons it isn't safe (empty when safe).
    var reasons: [String]
    /// Plain notes that don't block anything ("You started it from your terminal").
    var notes: [String]
    /// What quitting does.
    var effect: String
    var action: SuggestedAction
    var actionTitle: String
}

struct Insight: Hashable {
    var usage: Usage
    var safety: Safety
    /// Smart close-after time for things Automate can close (filled in by the Engine).
    var smart: UsageMemory.Pick? = nil
}

enum Insights {
    /// Apps that keep the Mac (or your other work) running. Never suggested, never quit from Watcher.
    static let protectedApps: Set<String> = [
        "Finder", "Dock", "SystemUIServer", "ControlCenter", "NotificationCenter", "loginwindow", "Spotlight",
        "WindowManager", "TextInputMenuAgent", "universalAccessAuthWarn", "Watcher", "Slop Cleaner", "Claude", "Simulator",
        "CoreServicesUIAgent", "AirPlayUIAgent", "Siri",
    ]

    static let recentUse: TimeInterval = 15 * 60
    /// Claude sessions: never touch one used in the last 30 min; under 6 h needs a confirm.
    static let sessionRecent: TimeInterval = 30 * 60
    static let sessionSafeIdle: TimeInterval = 6 * 3600

    static func make(_ t: Thing, _ c: RuleContext, byID: [String: Thing]) -> Insight {
        Insight(usage: usage(t, c), safety: safety(t, c, byID: byID))
    }

    // MARK: - Last used

    static func usage(_ t: Thing, _ c: RuleContext) -> Usage {
        let h = c.history
        let watched = h.observed(t.id, now: c.now)
        func since(_ d: Date?) -> TimeInterval? { d.map { c.now.timeIntervalSince($0) } }

        switch t.kind {
        case .app:
            if let f = c.frontmostPID, t.processes.contains(where: { $0.pid == f }) {
                return Usage(text: "In use now", idleFor: 0, inUseNow: true, exact: true)
            }
            if let s = since(h.lastFront[t.id]) {
                return Usage(text: "Last used \(Format.ago(s))", idleFor: s, inUseNow: false, exact: true)
            }
            return Usage(text: "Not used since Slop Cleaner started \(Format.ago(watched))", idleFor: watched,
                         inUseNow: false, exact: false)

        case .androidEmulator(let key, _), .iosSimulator(let key, _):
            if c.driven.contains(key) || c.driven.contains(key.hasPrefix("emulator-") ? "*android" : "*ios") {
                return Usage(text: "Being driven right now", idleFor: 0, inUseNow: true, exact: true)
            }
            if let s = h.sinceDriven(key, now: c.now) {
                return Usage(text: "Last driven \(Format.ago(s))", idleFor: s, inUseNow: false, exact: true)
            }
            return Usage(text: "Not driven since Slop Cleaner started \(Format.ago(watched))",
                         idleFor: watched, inUseNow: false, exact: false)

        case .devServer:
            if !t.clients.isEmpty {
                return Usage(text: "In use by \(t.clients.joined(separator: ", "))", idleFor: 0, inUseNow: true, exact: true)
            }
            if let s = since(h.lastClient[t.id]) {
                return Usage(text: "Last client \(Format.ago(s))", idleFor: s, inUseNow: false, exact: true)
            }
            return Usage(text: "No clients since Slop Cleaner started \(Format.ago(watched))", idleFor: watched,
                         inUseNow: false, exact: false)

        case .claudeSession:
            if let last = t.externalLastUse {
                let s = max(0, c.now.timeIntervalSince(last))
                if s < 60 { return Usage(text: "Working now", idleFor: 0, inUseNow: true, exact: true) }
                return Usage(text: "Last activity \(Format.ago(s))", idleFor: s, inUseNow: false, exact: true)
            }
            if let s = since(h.lastBusy[t.id]), s < 15 {
                return Usage(text: "Working now", idleFor: 0, inUseNow: true, exact: true)
            }
            if let s = since(h.lastBusy[t.id]) {
                return Usage(text: "Last active \(Format.ago(s))", idleFor: s, inUseNow: false, exact: true)
            }
            return Usage(text: "Quiet since Slop Cleaner started \(Format.ago(watched))", idleFor: watched, inUseNow: false, exact: false)

        default:
            if !t.clients.isEmpty {
                return Usage(text: "In use by \(t.clients.joined(separator: ", "))", idleFor: 0, inUseNow: true, exact: true)
            }
            if let s = since(h.lastBusy[t.id]) {
                // Busy isn't the same as in use: a stuck process is busy too. Only a Claude session
                // that's busy is someone's work in progress.
                if s < 15 {
                    let isSession: Bool = { if case .claudeSession = t.kind { return true }; return false }()
                    return Usage(text: isSession ? "Working now" : "Busy right now", idleFor: 0, inUseNow: isSession, exact: true)
                }
                return Usage(text: "Last active \(Format.ago(s))", idleFor: s, inUseNow: false, exact: true)
            }
            return Usage(text: "Quiet since Slop Cleaner started \(Format.ago(watched))", idleFor: watched,
                         inUseNow: false, exact: false)
        }
    }

    // MARK: - Safety

    static func safety(_ t: Thing, _ c: RuleContext, byID: [String: Thing]) -> Safety {
        var blocked: [String] = []
        var caution: [String] = []
        var notes: [String] = []
        let u = usage(t, c)

        if t.processes.contains(where: { $0.pid == c.selfPID }) { blocked.append("This is Slop Cleaner itself.") }
        if Rules.protectedNames.contains(t.root.name) || protectedApps.contains(t.title)
            || Guard.neverNames.contains(t.root.name) || Guard.neverPaths.contains(where: { t.root.path.hasPrefix($0) }) && t.kind != .system {
            blocked.append(t.title == "Claude"
                ? "Quitting Claude would stop every open Claude session at once."
                : "macOS or your setup depends on it.")
        }

        let effect: String
        let action: SuggestedAction
        let actionTitle: String
        switch t.kind {
        case .androidEmulator(let serial, let avd):
            effect = "Saves a snapshot and shuts it down. Start it again with: emulator -avd \(avd) -port \(serial.dropFirst(9))"
            action = .stopEmulator(serial: serial); actionTitle = "Shut down"
            if let lock = c.locks([serial, avd]), !lock.stale { blocked.append("Reserved by \(lock.holder).") }
            if u.inUseNow { blocked.append("Something is driving it right now.") }
        case .iosSimulator(let udid, let name):
            effect = "Shuts it down. Its apps and data stay." + (t.origin != nil ? " The attached panel will show it as off." : "")
            action = .shutdownSimulator(udid: udid); actionTitle = "Shut down"
            if let lock = c.locks([udid, name]), !lock.stale { blocked.append("Reserved by \(lock.holder).") }
            if u.inUseNow { blocked.append("Something is driving it right now.") }
        case .app:
            effect = "Quits it like ⌘Q. It asks about unsaved work first."
            action = .quitApp(pid: t.root.pid, start: t.root.startTime); actionTitle = "Quit"
            if u.inUseNow { blocked.append("You're using it right now.") }
            else if u.exact && u.idleFor < recentUse { caution.append("You used it \(Format.ago(u.idleFor)).") }
        case .claudeSession:
            effect = "Stops its background process. The session and its history stay in the Claude app, which starts it again when you open it."
            action = .stopSession(pid: t.root.pid, start: t.root.startTime); actionTitle = "Stop"
            let busy = c.history.lastBusy[t.id].map { c.now.timeIntervalSince($0) }
            if u.inUseNow {
                blocked.append("It's working right now.")
            } else if !u.exact {
                blocked.append("The Claude app hasn't said when it was last used.")
            } else if u.idleFor < sessionRecent {
                blocked.append("It was used \(Format.ago(u.idleFor)), so it may still be mid-task.")
            } else if let b = busy, b < 120 {
                blocked.append("Its process was busy \(Format.ago(b)).")
            } else if u.idleFor < sessionSafeIdle {
                caution.append("You used it \(Format.ago(u.idleFor)).")
            }
            let started = byID.values.filter { $0.ownerID == t.id }
            if !started.isEmpty {
                caution.append("It started \(started.map(\.title).joined(separator: ", ")), still running.")
            }
        case .system:
            effect = "Can't be quit from Slop Cleaner."
            action = .none; actionTitle = ""
            blocked.append("It's a system process.")
        case .devServer:
            effect = "Stops the server. Anything using it loses its connection until you start it again."
            action = .terminate(pid: t.root.pid, start: t.root.startTime); actionTitle = "Quit"
        case .testRun:
            effect = "Stops the run early. Its results so far are lost."
            action = .terminate(pid: t.root.pid, start: t.root.startTime); actionTitle = "Stop"
            caution.append("A test or build is still running.")
        case .buildDaemon:
            effect = "Stops the daemon. The next build starts a fresh one (a little slower)."
            action = .terminate(pid: t.root.pid, start: t.root.startTime); actionTitle = "Stop"
        case .process:
            effect = "Asks it to stop (like closing it normally)."
            action = .terminate(pid: t.root.pid, start: t.root.startTime); actionTitle = "Quit"
        }

        // Something else depends on it.
        if !t.clients.isEmpty {
            blocked.append("\(t.clients.joined(separator: ", ")) \(t.clients.count == 1 ? "is" : "are") connected to it right now.")
        }
        // Part of a Claude session that's working.
        if let owner = t.ownerID {
            if let busy = c.history.lastBusy[owner], c.now.timeIntervalSince(busy) < 10 * 60 {
                blocked.append("The Claude session that started it was working \(Format.ago(c.now.timeIntervalSince(busy))).")
            } else if byID[owner] != nil {
                notes.append(t.ownerLabel ?? "Started by a Claude session.")
            }
        }
        // Started by an open app that isn't a terminal or editor: it's that app's work, not yours to stop here.
        // (Only a real app: when the session that ran something has ended, all that's left is its command.)
        if let app = t.originApp, !Guard.launcherApps.contains(app), t.kind == .process || t.kind == .devServer {
            blocked.append("It's part of \(app)'s work. Quit \(app) if you want it gone.")
        }
        if let o = t.origin { notes.append(o + ".") }
        if case .devServer = t.kind, !t.listenPorts.isEmpty {
            notes.append("Listening on port\(t.listenPorts.count == 1 ? "" : "s") \(t.listenPorts.map(String.init).joined(separator: ", ")).")
        }

        let verdict: Safety.Verdict = !blocked.isEmpty ? .blocked : !caution.isEmpty ? .caution : .safe
        return Safety(verdict: verdict, reasons: blocked + caution, notes: notes, effect: effect,
                      action: verdict == .blocked ? .none : action, actionTitle: actionTitle)
    }
}
