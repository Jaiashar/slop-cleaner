import Foundation

enum Sensitivity: String, CaseIterable, Identifiable {
    case relaxed, normal, eager
    var id: String { rawValue }
    var title: String {
        switch self {
        case .relaxed: return "Relaxed"
        case .normal: return "Normal"
        case .eager: return "Eager"
        }
    }
    var explanation: String {
        switch self {
        case .relaxed: return "Only speaks up when something has been wasteful for a long while."
        case .normal: return "Idle emulators after 10 min, runaway processes after 15 min."
        case .eager: return "Speaks up within a couple of minutes. Good for testing."
        }
    }
}

struct Thresholds {
    var emulatorCPU: Double = 150          // % of one core
    var simulatorCPU: Double = 60
    var deviceWindow: TimeInterval = 10 * 60
    var runawayCPU: Double = 90
    var runawayWindow: TimeInterval = 15 * 60
    var staleServerAge: TimeInterval = 24 * 3600
    var idleDeviceAge: TimeInterval = 12 * 3600
    var buildDaemonAge: TimeInterval = 3 * 3600
    var swapBytes: UInt64 = 8 * 1_073_741_824
    var claudeIdleCount = 5
    var claudeIdleAge: TimeInterval = 24 * 3600
    var claudeQuietWindow: TimeInterval = 10 * 60

    static func make(_ s: Sensitivity) -> Thresholds {
        var t = Thresholds()
        switch s {
        case .normal: break
        case .relaxed:
            t.emulatorCPU = 250; t.simulatorCPU = 100
            t.deviceWindow = 30 * 60; t.runawayWindow = 30 * 60
            t.staleServerAge = 3 * 24 * 3600; t.idleDeviceAge = 24 * 3600
            t.swapBytes = 16 * 1_073_741_824; t.claudeIdleCount = 15; t.claudeIdleAge = 3 * 24 * 3600
        case .eager:
            t.emulatorCPU = 80; t.simulatorCPU = 40
            t.deviceWindow = 2 * 60; t.runawayWindow = 2 * 60
            t.staleServerAge = 6 * 3600; t.idleDeviceAge = 2 * 3600
            t.buildDaemonAge = 3600; t.swapBytes = 4 * 1_073_741_824
            t.claudeIdleCount = 2; t.claudeIdleAge = 6 * 3600; t.claudeQuietWindow = 2 * 60
        }
        return t
    }
}

enum SuggestedAction: Hashable {
    case stopEmulator(serial: String)
    case shutdownSimulator(udid: String)
    case terminate(pid: Int32, start: Date)
    case quitApp(pid: Int32, start: Date)
    /// Stops an idle Claude Code session's background process. The session stays in the Claude app.
    case stopSession(pid: Int32, start: Date)
    /// Several things at once (each re-checked first), e.g. every idle Claude session.
    case sweep(ids: [String])
    case copyCommand(String)
    case openClaude
    /// Bring an app to the front (e.g. one that didn't quit, so you can see what it's asking).
    case showApp(pid: Int32)
    case none

    var isDestructive: Bool {
        switch self {
        case .stopEmulator, .shutdownSimulator, .terminate, .quitApp, .stopSession, .sweep: return true
        default: return false
        }
    }
}

enum Severity: Int, Comparable {
    case info = 0, suggest = 1, urgent = 2
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

struct Suggestion: Identifiable, Hashable {
    /// Stable across restarts, used for snooze and "don't suggest again": e.g. "idle-emulator:Pixel_8_API_35".
    let id: String
    let thingID: String?
    let severity: Severity
    let symbol: String
    let title: String
    let detail: String
    let evidence: [String]
    let action: SuggestedAction
    let actionTitle: String
    /// Shown instead of the button when we shouldn't act (e.g. a QA lock is held).
    var blockedNote: String? = nil
    let notify: Bool
    /// Plain name for the ignore list.
    let ignoreLabel: String
    /// Optional rows shown in the card (e.g. each idle Claude session), with a link when there is one.
    var items: [String] = []
    var itemLinks: [String: URL] = [:]
}

struct RuleContext {
    var things: [Thing]
    var stats: SystemStats
    var history: History
    var now: Date
    var thresholds: Thresholds
    var driven: Set<String>
    var locks: (_ keys: [String]) -> QALock?
    var frontmostPID: Int32?
    var selfPID: Int32 = getpid()
}

enum Rules {
    /// Never flagged as runaway: they're busy because of something else, or can't be restarted safely.
    static let protectedNames: Set<String> = [
        "WindowServer", "kernel_task", "launchd", "loginwindow", "logd", "mds", "mds_stores", "mdworker_shared",
        "coreaudiod", "hidd", "Watcher", "Slop Cleaner", "backupd", "softwareupdated", "XprotectService", "syspolicyd",
    ]

    /// Every insight at once (tests and the open popover). Rules use `InsightSource` to compute only what they need.
    static func insights(_ c: RuleContext) -> [String: Insight] {
        let src = InsightSource(c)
        for t in c.things { _ = src[t] }
        return src.cache
    }

    static func evaluate(_ c: RuleContext, insights given: [String: Insight]? = nil) -> [Suggestion] {
        let src = InsightSource(c)
        if let given { src.cache = given }
        return evaluate(c, src)
    }

    static func evaluate(_ c: RuleContext, _ src: InsightSource) -> [Suggestion] {
        var out: [Suggestion] = []
        for t in c.things {
            switch t.kind {
            case .androidEmulator(let serial, let avd):
                if let s = device(t, c, src[t], key: serial, cpuLimit: c.thresholds.emulatorCPU, idPart: avd,
                                  afterNote: "Shutting down saves its snapshot.") { out.append(s) }
            case .iosSimulator(let udid, let name):
                if let s = device(t, c, src[t], key: udid, cpuLimit: c.thresholds.simulatorCPU, idPart: name,
                                  afterNote: "Shutting down keeps its apps and data.") { out.append(s) }
            case .devServer, .buildDaemon:
                if let s = staleTool(t, c, src) { out.append(s) } else if let s = runaway(t, c, src) { out.append(s) }
            case .app:
                if let s = runaway(t, c, src) { out.append(s) }
            case .system:
                if let s = macOSJob(t, c) ?? runaway(t, c, src) { out.append(s) }
            case .process:
                if let s = macOSJob(t, c) ?? runaway(t, c, src) ?? leftover(t, c, src) { out.append(s) }
            case .claudeSession, .testRun:
                break
            }
        }
        if let s = claudePile(c, src) { out.append(s) }
        if let s = memory(c) { out.append(s) }
        if let s = heat(c, existing: out) { out.append(s) }
        return out.sorted { ($0.severity, $1.title) > ($1.severity, $0.title) }
    }

    // MARK: - Devices

    private static func device(_ t: Thing, _ c: RuleContext, _ i: Insight, key: String, cpuLimit: Double,
                               idPart: String, afterNote: String) -> Suggestion? {
        let window = c.thresholds.deviceWindow
        if i.usage.inUseNow { return nil }
        if let since = c.history.sinceDriven(key, now: c.now), since < window { return nil }
        // Anything other than a reservation (shown as a note) means leave it alone.
        let lockReason = i.safety.reasons.first { $0.hasPrefix("Reserved by") }
        if i.safety.verdict != .safe && lockReason == nil { return nil }

        let uptime = c.now.timeIntervalSince(t.startedAt)
        let avg = c.history.average(t.id, window: window, now: c.now)
        let hot = (avg ?? 0) >= cpuLimit
        let longIdle = uptime >= c.thresholds.idleDeviceAge && i.usage.idleFor >= window
        guard hot || longIdle else { return nil }

        let kindWord = key.hasPrefix("emulator-") ? "emulator" : "simulator"
        let title = hot ? "\(t.title) is using \(Format.coresPhrase(avg ?? t.cpu))"
                        : "\(t.title) has been on for \(Format.duration(uptime))"
        let used = i.usage.text.capitalizedFirst
        let detail = hot ? "Running \(Format.duration(uptime)). \(used). \(afterNote)"
                         : "It isn't using much CPU, but it's holding \(Format.bytes(t.memory)). \(used). \(afterNote)"
        var s = Suggestion(
            id: "idle-\(kindWord):\(idPart)", thingID: t.id,
            severity: hot ? ((avg ?? 0) >= 400 ? .urgent : .suggest) : .info,
            symbol: t.symbol, title: title, detail: detail,
            evidence: [Format.cores(avg ?? t.cpu), Format.bytes(t.memory), "up \(Format.duration(uptime))", "nobody driving"],
            action: i.safety.action, actionTitle: "Shut down", notify: hot,
            ignoreLabel: "\(t.title)")
        if let lockReason { s.blockedNote = String(lockReason.dropLast()) }
        return s
    }

    // MARK: - Runaway processes

    private static func runaway(_ t: Thing, _ c: RuleContext, _ src: InsightSource) -> Suggestion? {
        let window = c.thresholds.runawayWindow
        guard t.cpu >= c.thresholds.runawayCPU * 0.5,      // cheap: not even busy right now
              let avg = c.history.average(t.id, window: window, now: c.now), avg >= c.thresholds.runawayCPU else { return nil }
        let i = src[t]
        if t.processes.contains(where: { $0.pid == c.selfPID }) { return nil }
        if let f = c.frontmostPID, t.processes.contains(where: { $0.pid == f }) { return nil } // you're using it
        let hot = t.hottest
        if protectedNames.contains(hot.name) || protectedNames.contains(t.title)
            || Guard.neverNames.contains(hot.name) || Guard.neverNames.contains(t.title) { return nil }
        if Insights.protectedApps.contains(t.title) { return nil }
        if !t.clients.isEmpty { return nil }                       // busy because something is using it
        if t.kind != .system && i.safety.verdict == .blocked { return nil }

        let evidence = [Format.cores(avg), "for \(Format.duration(window))+", Format.bytes(t.memory)]
        let title = "\(t.title) has used \(Format.coresPhrase(avg)) for \(Format.duration(window))"
        switch t.kind {
        case .system:
            return Suggestion(
                id: "runaway:\(t.title)", thingID: t.id, severity: avg >= 180 ? .urgent : .suggest, symbol: t.symbol,
                title: title,
                detail: "\(t.title) is a system process, so Slop Cleaner can't restart it. Running the command restarts it (macOS brings it back fresh).",
                evidence: evidence, action: .copyCommand("sudo killall \(hot.name)"), actionTitle: "Copy command",
                notify: true, ignoreLabel: t.title)
        case .app:
            if hot.pid == t.root.pid {
                return Suggestion(
                    id: "runaway:\(t.title)", thingID: t.id, severity: .suggest, symbol: t.symbol, title: title,
                    detail: "It's been steady in the background, which can mean it's stuck. Quitting it frees the CPU.",
                    evidence: evidence, action: .quitApp(pid: t.root.pid, start: t.root.startTime), actionTitle: "Quit",
                    notify: true, ignoreLabel: t.title)
            }
            return Suggestion(
                id: "runaway:\(t.title)", thingID: t.id, severity: .suggest, symbol: t.symbol, title: title,
                detail: "Most of it is \(hot.name) (\(Format.cores(hot.cpu))). If it's a tab or window you don't need, closing it in \(t.title) should help. Slop Cleaner won't stop part of an app for you.",
                evidence: evidence, action: .none, actionTitle: "",
                notify: true, ignoreLabel: t.title)
        default:
            return Suggestion(
                id: "runaway:\(t.title)", thingID: t.id, severity: avg >= 180 ? .urgent : .suggest, symbol: t.symbol,
                title: title, detail: "It's been busy the whole time, which can mean it's stuck. \(t.subtitle.capitalizedFirst).",
                evidence: evidence, action: .terminate(pid: t.root.pid, start: t.root.startTime), actionTitle: "Quit it",
                notify: true, ignoreLabel: t.title)
        }
    }

    // MARK: - Dev servers and build daemons left running

    private static func staleTool(_ t: Thing, _ c: RuleContext, _ src: InsightSource) -> Suggestion? {
        let uptime = c.now.timeIntervalSince(t.startedAt)
        let isDaemon: Bool = { if case .buildDaemon = t.kind { return true }; return false }()
        let limit = isDaemon ? c.thresholds.buildDaemonAge : c.thresholds.staleServerAge
        guard uptime >= limit else { return nil }
        let i = src[t]
        // Never while something is connected to it or the session that started it is working.
        guard i.safety.verdict == .safe, !i.usage.inUseNow, i.usage.idleFor >= c.thresholds.deviceWindow else { return nil }
        let quiet = c.history.average(t.id, window: 10 * 60, now: c.now)
        if isDaemon {
            guard let q = quiet, q < 2, t.memory >= 500 * 1_048_576 else { return nil }
        }
        let heavy = (quiet ?? t.cpu) >= 10 || t.memory >= 1_073_741_824
        var detail = "Running for \(Format.duration(uptime)) \(t.subtitle). \(i.usage.text.capitalizedFirst). Quitting frees \(Format.bytes(t.memory))."
        if let o = t.ownerLabel ?? t.origin { detail += " \(o)." }
        return Suggestion(
            id: "stale:\(t.title):\(t.subtitle)", thingID: t.id, severity: heavy ? .suggest : .info, symbol: t.symbol,
            title: "\(t.title) has been running \(Format.duration(uptime))", detail: detail,
            evidence: [Format.cores(quiet ?? t.cpu), Format.bytes(t.memory), "up \(Format.duration(uptime))"],
            action: .terminate(pid: t.root.pid, start: t.root.startTime), actionTitle: "Quit it",
            notify: heavy && !isDaemon, ignoreLabel: "\(t.title) \(t.subtitle)")
    }

    // MARK: - Machine-wide

    private static func claudePile(_ c: RuleContext, _ src: InsightSource) -> Suggestion? {
        let sessions = c.things.filter { if case .claudeSession = $0.kind { return true }; return false }
        var ins: [String: Insight] = [:]
        for t in sessions { ins[t.id] = src[t] }
        // Only sessions that are safe to stop right now, idle past the limit, by the Claude app's own record.
        let idle = sessions.filter { s in
            guard let i = ins[s.id], i.safety.verdict == .safe, i.usage.exact else { return false }
            return i.usage.idleFor >= c.thresholds.claudeIdleAge
        }.sorted { (ins[$0.id]?.usage.idleFor ?? 0) > (ins[$1.id]?.usage.idleFor ?? 0) }
        guard idle.count >= c.thresholds.claudeIdleCount else { return nil }
        let mem = idle.reduce(UInt64(0)) { $0 + $1.memory }
        let rows = idle.prefix(8).map { s -> String in
            let idleFor = ins[s.id].map { Format.duration($0.usage.idleFor) } ?? "?"
            return "“\(s.title)” · idle \(idleFor) · \(Format.bytes(s.memory))"
        }
        var s = Suggestion(
            id: "claude-pile", thingID: nil, severity: mem >= 4 * 1_073_741_824 ? .suggest : .info, symbol: "terminal",
            title: "\(idle.count) Claude Code sessions haven't been used in over \(Format.duration(c.thresholds.claudeIdleAge))",
            detail: "Each keeps a background process holding memory. Stopping them frees \(Format.bytes(mem)). The sessions stay in the Claude app with all their history, and start again when you open one.",
            evidence: ["\(idle.count) of \(sessions.count) idle", Format.bytes(mem)],
            action: .sweep(ids: idle.map(\.id)), actionTitle: "Stop \(idle.count) idle sessions", notify: true,
            ignoreLabel: "Idle Claude sessions")
        s.items = rows + (idle.count > 8 ? ["and \(idle.count - 8) more"] : [])
        for (row, session) in zip(rows, idle.prefix(8)) {
            if let url = ClaudeLinks.url(for: session) { s.itemLinks[row] = url }
        }
        return s
    }

    /// macOS's own background jobs that can run hot for a long time. Never stoppable, but worth explaining.
    static let macOSJobs: [String: (name: String, what: String)] = [
        "mediaanalysisd": ("Photos analysis", "macOS is analyzing your photo library (people, objects, text in images). It finishes on its own, fastest while your Mac is plugged in and idle."),
        "photoanalysisd": ("Photos analysis", "macOS is analyzing your photo library. It finishes on its own, fastest while your Mac is plugged in and idle."),
        "mds_stores": ("Spotlight indexing", "Spotlight is indexing files, often after lots of new files appear (builds, node_modules, downloads). Adding big build folders to System Settings → Spotlight → Search Privacy keeps it lighter."),
        "mdworker_shared": ("Spotlight indexing", "Spotlight is reading new or changed files. It settles down once they're indexed."),
        "mds": ("Spotlight indexing", "Spotlight is updating its index. It settles down on its own."),
        "backupd": ("Time Machine", "A Time Machine backup is running. It finishes on its own."),
        "softwareupdated": ("Software Update", "macOS is downloading or preparing an update."),
        "kernel_task": ("Keeping your Mac cool", "macOS is holding back CPU to keep your Mac cool. Usually something else is running hot; see the list below."),
        "XprotectService": ("Security scan", "macOS's built-in malware protection is scanning. It finishes on its own."),
        "syspolicyd": ("Security checks", "macOS is checking newly opened or built apps. It settles down on its own."),
    ]

    private static func macOSJob(_ t: Thing, _ c: RuleContext) -> Suggestion? {
        let name = t.root.name
        guard let job = macOSJobs[name], t.cpu >= 50,
              let avg = c.history.average(t.id, window: 30 * 60, now: c.now), avg >= 80 else { return nil }
        return Suggestion(
            id: "macos-job:\(name)", thingID: t.id, severity: .info, symbol: "apple.logo",
            title: "\(job.name) has used \(Format.coresPhrase(avg)) for 30 min",
            detail: "\(job.what) It's part of macOS (\(name)), so Slop Cleaner won't stop it.",
            evidence: [Format.cores(avg), "macOS", "up \(Format.duration(c.now.timeIntervalSince(t.startedAt)))"],
            action: .none, actionTitle: "", notify: false, ignoreLabel: job.name)
    }

    /// Agent tools left running after the session that started them ended (their parent is gone).
    private static func leftover(_ t: Thing, _ c: RuleContext, _ src: InsightSource) -> Suggestion? {
        let age = c.now.timeIntervalSince(t.startedAt)
        guard t.root.ppid == 1, t.root.uid >= 500, age >= 3600, t.cpu < 5, !t.root.args.isEmpty else { return nil }
        let a = t.root.args.joined(separator: " ").lowercased()
        let markers = ["mcp", "playwright", "puppeteer", "--headless", "chrome-headless-shell", "chromedriver", "--remote-debugging-port"]
        guard markers.contains(where: { a.contains($0) }),
              let avg = c.history.average(t.id, window: 10 * 60, now: c.now), avg < 2 else { return nil }
        let i = src[t]
        guard i.safety.verdict == .safe, !i.usage.inUseNow else { return nil }
        return Suggestion(
            id: "leftover:\(t.title)", thingID: t.id, severity: .info, symbol: "puzzlepiece.extension",
            title: "\(t.title) was left behind",
            detail: "It looks like an agent tool (a browser or MCP server) whose session already ended. It's been idle for \(Format.duration(age)) and holds \(Format.bytes(t.memory)).",
            evidence: [Format.bytes(t.memory), "up \(Format.duration(age))", "no parent"],
            action: i.safety.action, actionTitle: "Quit it", notify: false, ignoreLabel: t.title)
    }

    private static func memory(_ c: RuleContext) -> Suggestion? {
        guard c.stats.pressureLevel >= 2 else { return nil }
        let top = c.things.sorted { $0.memory > $1.memory }.prefix(3)
        let names = top.map { "\($0.title) \(Format.bytes($0.memory))" }
        return Suggestion(
            id: "memory", thingID: nil, severity: c.stats.pressureLevel >= 4 ? .urgent : .suggest, symbol: "memorychip",
            title: "Your Mac is short on memory",
            detail: "macOS is squeezing memory and using the SSD as overflow (swap), which slows things down. The biggest holders: \(names.joined(separator: ", ")).",
            evidence: ["\(Format.bytes(c.stats.memoryUsed)) of \(Format.bytes(c.stats.memoryTotal))", "swap \(Format.bytes(c.stats.swapUsed))"],
            action: .none, actionTitle: "", notify: true, ignoreLabel: "Memory warnings")
    }

    private static func heat(_ c: RuleContext, existing: [Suggestion]) -> Suggestion? {
        guard c.stats.thermal == .serious || c.stats.thermal == .critical else { return nil }
        guard let top = c.things.max(by: { $0.cpu < $1.cpu }) else { return nil }
        let covered = existing.contains { $0.thingID == top.id }
        return Suggestion(
            id: "heat", thingID: nil, severity: .urgent, symbol: "thermometer.high",
            title: "Your Mac is running hot",
            detail: "Most of the load is \(top.title) (\(Format.cores(top.cpu)))." + (covered ? " See its card." : ""),
            evidence: [c.stats.thermalText, "\(Int(c.stats.cpuFraction * 100))% CPU"],
            action: .none, actionTitle: "", notify: !covered, ignoreLabel: "Heat warnings")
    }
}

/// Decides whether a suggestion becomes a notification right now.
enum NotificationGate {
    static func cooldown(_ s: Severity) -> TimeInterval {
        switch s {
        case .urgent, .suggest: return 2 * 3600
        case .info: return 12 * 3600
        }
    }

    static func shouldNotify(_ s: Suggestion, now: Date, lastNotified: Date?, snoozedUntil: Date?, ignored: Bool,
                             enabled: Bool, quiet: QuietHours?) -> Bool {
        guard enabled, s.notify, !ignored else { return false }
        if let until = snoozedUntil, until > now { return false }
        if let q = quiet, q.contains(now) { return false }
        if let last = lastNotified, now.timeIntervalSince(last) < cooldown(s.severity) { return false }
        return true
    }
}

struct QuietHours: Equatable {
    var startHour: Int
    var endHour: Int

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let h = calendar.component(.hour, from: date)
        if startHour == endHour { return false }
        return startHour < endHour ? (h >= startHour && h < endHour) : (h >= startHour || h < endHour)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Computes each thing's insight once, only when something asks for it.
final class InsightSource {
    let c: RuleContext
    let byID: [String: Thing]
    var cache: [String: Insight] = [:]
    /// Extra step for each new insight (the Engine adds Smart timing here).
    var enrich: ((Thing, inout Insight) -> Void)?

    init(_ c: RuleContext) {
        self.c = c
        byID = Dictionary(c.things.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    subscript(t: Thing) -> Insight {
        if let i = cache[t.id] { return i }
        var i = Insights.make(t, c, byID: byID)
        enrich?(t, &i)
        cache[t.id] = i
        return i
    }
}
