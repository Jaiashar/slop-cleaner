import AppKit
import Combine
import Foundation

/// What the UI shows. Lives on the main thread; the Engine does the work on its own queue.
final class AppState: ObservableObject {
    @Published private(set) var stats = SystemStats()
    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var things: [Thing] = []
    @Published private(set) var insights: [String: Insight] = [:]
    @Published private(set) var systemSeries: [Double] = []
    @Published private(set) var thingSeries: [String: [Double]] = [:]
    @Published private(set) var peak: (cpu: Double, at: Date)? = nil
    @Published private(set) var lastUpdate = Date.distantPast
    @Published private(set) var running: Set<String> = []
    /// Automate: thing id → when it will be closed.
    @Published private(set) var pendingAuto: [String: Date] = [:]
    @Published private(set) var autoLog: [(at: Date, text: String)] = []
    @Published var toast: String? = nil
    // Popover UI state (kept here so the debug snapshot can set it).
    @Published var tab: PopoverTab = .now
    @Published var uiQuery = ""
    @Published var uiExpanded: Set<String> = []

    let prefs = Preferences()
    let notifier = Notifier()
    var onOpenRequest: (() -> Void)?

    /// Full lists are only published while the popover is open, so a closed Watcher stays near 0% CPU.
    var popoverVisible = false { didSet { if popoverVisible { publishDetail() } } }

    private let engine = Engine()
    private var timer: Timer?
    private var latest: Engine.Tick?
    private var allSuggestions: [Suggestion] = []
    private var lastNotified: [String: Date] = [:]
    private var delivered: Set<String> = []
    private var bag: Set<AnyCancellable> = []
    private var ticking = false
    private var beat = 0
    /// Demo data on screen (README screenshots): live updates pause.
    fileprivate(set) var demo = false
    /// Apps asked to quit that are still open: thing id → (title, pid, start, asked at).
    private var didntQuit: [String: (title: String, pid: Int32, start: Date, at: Date)] = [:]

    func start() {
        notifier.onResponse = { [weak self] id, r in self?.handle(id: id, response: r) }
        notifier.setup()
        prefs.$sensitivity.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) {
            [engine] _ in engine.queue.sync { engine.saveHistory() }
        }
        refresh()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.beat += 1
            // Every 5 s while the popover is open or something is about to close; otherwise every 10 s.
            if self.popoverVisible || !self.pendingAuto.isEmpty || self.beat % 2 == 0 { self.refresh() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        guard !ticking else { return }
        ticking = true
        let thresholds = Thresholds.make(prefs.sensitivity)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let detail = popoverVisible
        engine.queue.async { [engine] in
            let tick = engine.tick(thresholds: thresholds, frontmostPID: front, detail: detail)
            DispatchQueue.main.async { self.apply(tick) }
        }
    }

    private func apply(_ tick: Engine.Tick) {
        ticking = false
        if demo { return }
        latest = tick
        stats = tick.stats
        systemSeries = tick.systemSeries
        peak = tick.peak
        lastUpdate = Date()
        allSuggestions = tick.suggestions + didntQuitFlags(tick)
        let visible = allSuggestions.filter { !prefs.isHidden($0.id) }
        if visible != suggestions { suggestions = visible }
        if popoverVisible { publishDetail() }
        notifyIfNeeded(allSuggestions)
        runAutomation(tick)
    }

    private func publishDetail() {
        guard !demo, let tick = latest else { return }
        things = tick.things
        insights = tick.insights
        thingSeries = tick.thingSeries
    }

    // MARK: - Notifications

    private func notifyIfNeeded(_ list: [Suggestion]) {
        let now = Date()
        let ids = Set(list.map(\.id))
        let gone = delivered.subtracting(ids)
        notifier.withdraw(Array(gone))
        delivered.subtract(gone)

        for s in list where !running.contains(s.id) {
            let ok = NotificationGate.shouldNotify(
                s, now: now, lastNotified: lastNotified[s.id], snoozedUntil: prefs.snoozes[s.id],
                ignored: prefs.ignored[s.id] != nil, enabled: prefs.notificationsOn, quiet: prefs.quietHours)
            guard ok else { continue }
            notifier.post(s)
            lastNotified[s.id] = now
            delivered.insert(s.id)
        }
    }

    private func handle(id: String, response: Notifier.Response) {
        if id.hasPrefix("auto:") || id.hasPrefix("autobatch:") {
            let ids = id.hasPrefix("auto:") ? [String(id.dropFirst(5))]
                                            : String(id.dropFirst(10)).components(separatedBy: "|")
            switch response {
            case .keep:
                ids.forEach { keepRunning($0, announce: ids.count == 1) }
                if ids.count > 1 { flash("Keeping all \(ids.count) running for the next 24 hours.") }
            case .act:
                for tid in ids { if let t = latest?.things.first(where: { $0.id == tid }) { autoClose(t, early: true) } }
            default:
                onOpenRequest?()
            }
            return
        }
        if id.hasPrefix("autodone:") { onOpenRequest?(); return }
        switch response {
        case .open, .keep:
            onOpenRequest?()
        case .snooze:
            snooze(id, for: 3600)
        case .ignore:
            if let s = allSuggestions.first(where: { $0.id == id }) { ignore(s) }
        case .act:
            if let s = allSuggestions.first(where: { $0.id == id }) { perform(s) } else { flash("That's already sorted.") }
        }
    }

    // MARK: - Acting safely

    enum Gate { case suggestion, manual(confirmedCaution: Bool), automatic(idleLimit: TimeInterval) }

    /// Re-reads everything (including connections) right before acting, and refuses if it's no longer safe.
    private func act(on thingID: String, key: String, gate: Gate, label: String, quiet: Bool = false,
                     done: ((Bool) -> Void)? = nil) {
        guard !running.contains(key) else { return }
        running.insert(key)
        let thresholds = Thresholds.make(prefs.sensitivity)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        engine.queue.async { [engine] in
            let tick = engine.tick(thresholds: thresholds, frontmostPID: front, freshConnections: true, focusID: thingID)
            DispatchQueue.main.async {
                self.apply(tick)
                guard let t = tick.things.first(where: { $0.id == thingID }), let i = tick.insights[thingID] else {
                    self.finish(key, quiet ? "" : "\(label) had already stopped.", ok: true, done: done)
                    return
                }
                if let reason = self.refusal(i, gate: gate) {
                    self.finish(key, quiet ? "" : "Didn't touch \(t.title): \(reason)", ok: false, done: done)
                    return
                }
                Task { @MainActor in
                    let outcome = await ActionRunner.run(i.safety.action, id: key, title: i.safety.actionTitle, label: t.title)
                    if outcome.stillOpen {
                        self.didntQuit[t.id] = (t.title, t.root.pid, t.root.startTime, Date())
                    }
                    if outcome.ok {
                        let engine = self.engine
                        engine.queue.async { engine.noteClosed(t) }
                        self.prefs.recordCleaned(bytes: t.memory, cpu: self.recentCPU(t))
                    }
                    self.notifier.withdraw([key])
                    self.finish(key, quiet ? "" : outcome.message, ok: outcome.ok, done: done)
                    if !quiet { self.refresh() }
                }
            }
        }
    }

    private func refusal(_ i: Insight, gate: Gate) -> String? {
        if i.safety.verdict == .blocked { return i.safety.reasons.first?.lowercasedFirst ?? "it isn't safe to stop." }
        if i.usage.inUseNow { return i.usage.text.lowercasedFirst + "." }
        guard i.safety.action.isDestructive else { return "there's nothing to stop." }
        switch gate {
        case .suggestion:
            if i.usage.inUseNow { return i.usage.text.lowercased() + "." }
            if i.safety.verdict == .caution, let r = i.safety.reasons.first { return r.lowercasedFirst }
        case .manual(let confirmed):
            if i.safety.verdict == .caution && !confirmed { return i.safety.reasons.first?.lowercasedFirst ?? "it's in use." }
        case .automatic(let limit):
            if !Automation.eligible(i, idleLimit: limit) {
                return i.safety.reasons.first?.lowercasedFirst ?? i.usage.text.lowercased() + "."
            }
        }
        return nil
    }

    private func finish(_ key: String, _ message: String, ok: Bool, done: ((Bool) -> Void)?) {
        running.remove(key)
        delivered.remove(key)
        flash(message)
        done?(ok)
    }

    private func recentCPU(_ t: Thing) -> Double {
        let series = latest?.thingSeries[t.id] ?? []
        return series.isEmpty ? t.cpu : series.suffix(24).reduce(0, +) / Double(min(24, series.count))
    }

    /// "Notes didn't quit": shown while the app is still open after being asked, for up to an hour.
    private func didntQuitFlags(_ tick: Engine.Tick) -> [Suggestion] {
        let now = Date()
        didntQuit = didntQuit.filter { id, v in
            now.timeIntervalSince(v.at) < 3600
                && tick.things.contains { $0.id == id && $0.root.pid == v.pid && $0.root.startTime == v.start }
        }
        return didntQuit.map { id, v in
            Suggestion(
                id: "didnt-quit:\(v.title)", thingID: id, severity: .suggest, symbol: "exclamationmark.bubble",
                title: "\(v.title) didn't quit",
                detail: "Slop Cleaner asked it to quit \(Format.ago(now.timeIntervalSince(v.at))). It's probably waiting on you (unsaved work, a dialog), or it may be stuck. Slop Cleaner never force-quits apps, so it's your call.",
                evidence: ["asked \(Format.ago(now.timeIntervalSince(v.at)))", "still open"],
                action: .showApp(pid: v.pid), actionTitle: "Show it", notify: true, ignoreLabel: "\(v.title) didn't quit")
        }
    }

    /// Async wrapper so sweeps can go one item at a time.
    private func actAsync(on thingID: String, key: String, gate: Gate, label: String) async -> Bool {
        await withCheckedContinuation { cont in
            act(on: thingID, key: key, gate: gate, label: label, quiet: true) { cont.resume(returning: $0) }
        }
    }

    /// Several things, one at a time, each re-checked right before it's touched.
    private func sweep(_ ids: [String], key: String, what: String) {
        guard !running.contains(key) else { return }
        running.insert(key)
        let before = latest?.things ?? []
        Task { @MainActor in
            var done = 0, skipped = 0
            var freed: UInt64 = 0
            for id in ids {
                let label = before.first { $0.id == id }?.title ?? "it"
                if await actAsync(on: id, key: "sweep:\(id)", gate: .suggestion, label: label) {
                    done += 1
                    freed += before.first { $0.id == id }?.memory ?? 0
                } else {
                    skipped += 1
                }
            }
            running.remove(key)
            notifier.withdraw([key])
            var msg = done == 0 ? "Nothing needed cleaning after all." : "Swept \(done) \(what)\(done == 1 ? "" : "s"), freed \(Format.bytes(freed))."
            if skipped > 0 { msg += " Left \(skipped) alone because \(skipped == 1 ? "it was" : "they were") in use or already gone." }
            flash(msg)
            refresh()
        }
    }

    /// The broom: every safe cleanup on screen, in one go.
    func sweepAll() {
        var ids: [String] = []
        for s in suggestions where s.blockedNote == nil {
            switch s.action {
            case .sweep(let list): ids += list
            case .stopEmulator, .shutdownSimulator, .terminate, .quitApp, .stopSession:
                if let id = s.thingID { ids.append(id) }
            default: break
            }
        }
        var seen = Set<String>()
        ids = ids.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { flash("Nothing to sweep."); return }
        sweep(ids, key: "sweep-all", what: "thing")
    }

    var sweepableCount: Int {
        var n = 0
        for s in suggestions where s.blockedNote == nil {
            switch s.action {
            case .sweep(let list): n += list.count
            case .stopEmulator, .shutdownSimulator, .terminate, .quitApp, .stopSession: n += s.thingID == nil ? 0 : 1
            default: break
            }
        }
        return n
    }

    /// From a suggestion card or its notification.
    func perform(_ s: Suggestion) {
        guard s.blockedNote == nil, s.action != .none, !running.contains(s.id) else { return }
        if case .sweep(let ids) = s.action {
            sweep(ids, key: s.id, what: "idle session")
            return
        }
        if s.action.isDestructive {
            // Anything that stops something must go through act(): fresh re-check, then the Guard.
            guard let thingID = s.thingID else { return }
            act(on: thingID, key: s.id, gate: .suggestion, label: s.ignoreLabel)
            return
        }
        running.insert(s.id)
        Task { @MainActor in
            let outcome = await ActionRunner.run(s.action, id: s.id, title: s.actionTitle, label: s.ignoreLabel)
            finish(s.id, outcome.message, ok: outcome.ok, done: nil)
        }
    }

    func performByID(_ id: String) {
        // "row:<title>" presses that row's Stop/Quit button (the same path as clicking it).
        if id.hasPrefix("row:") {
            let q = String(id.dropFirst(4))
            if let t = latest?.things.first(where: { $0.title == q }) { quit(t, confirmedCaution: false) }
            else { flash("Nothing called \(q) is running.") }
            return
        }
        if let s = allSuggestions.first(where: { $0.id == id }) { perform(s) } else { flash("No suggestion \(id) right now.") }
    }

    /// From the Quit button on a row.
    func quit(_ t: Thing, confirmedCaution: Bool) {
        guard latest?.insights[t.id] != nil else { return }
        act(on: t.id, key: "manual:\(t.id)", gate: .manual(confirmedCaution: confirmedCaution), label: t.title)
    }

    func isRunning(_ t: Thing) -> Bool { running.contains("manual:\(t.id)") }

    // MARK: - Automate

    private func runAutomation(_ tick: Engine.Tick) {
        let now = Date()
        var stillPending: [String: Date] = [:]
        var newly: [(thing: Thing, insight: Insight, limit: TimeInterval, setting: Double)] = []
        for t in tick.things {
            guard let cat = AutoCategory.of(t), let setting = prefs.autoLimit(cat), let i = tick.insights[t.id],
                  let limit = Automation.limit(setting: setting, insight: i) else { continue }
            let key = "auto:\(t.id)"
            if running.contains(key) { continue }                       // already being closed
            let eligible = Automation.eligible(i, idleLimit: limit) && !prefs.isKept(t.id)
            guard eligible else { continue }                            // used again: drop it quietly
            if let due = pendingAuto[t.id] {
                if due <= now { autoClose(t, early: false) } else { stillPending[t.id] = due }
            } else {
                stillPending[t.id] = now.addingTimeInterval(Automation.warning)
                newly.append((t, i, limit, setting))
            }
        }
        if stillPending != pendingAuto {
            // Withdraw heads-ups for anything no longer pending (used again, kept, or closed).
            let gone = Set(pendingAuto.keys).subtracting(stillPending.keys)
            notifier.withdraw(gone.map { "auto:\($0)" })
            pendingAuto = stillPending
        }
        postHeadsUp(newly)
    }

    /// One heads-up for one item; one grouped heads-up for many (never a flood).
    private func postHeadsUp(_ items: [(thing: Thing, insight: Insight, limit: TimeInterval, setting: Double)]) {
        guard let first = items.first else { return }
        if items.count == 1 {
            let (t, i, limit, setting) = first
            let why = setting < 0 ? (i.smart.map { " \($0.reason)." } ?? "") : ""
            notifier.postAuto(
                id: "auto:\(t.id)", title: "Closing \(t.title) in 5 minutes",
                body: "\(i.usage.text.capitalizedFirst), past the \(Format.duration(limit)) limit.\(why) Frees \(Format.bytes(t.memory)).",
                headsUp: true)
            return
        }
        let mem = items.reduce(UInt64(0)) { $0 + $1.thing.memory }
        let names = items.prefix(3).map { "“\($0.thing.title)”" }.joined(separator: ", ")
        let more = items.count > 3 ? " and \(items.count - 3) more" : ""
        let allSessions = items.allSatisfy { if case .claudeSession = $0.thing.kind { return true }; return false }
        let what = allSessions ? "idle Claude sessions" : "idle things"
        notifier.postAuto(
            id: "autobatch:" + items.map(\.thing.id).joined(separator: "|"),
            title: "Closing \(items.count) \(what) in 5 minutes",
            body: "\(names)\(more). Each went unused past its limit. Frees \(Format.bytes(mem)).",
            headsUp: true)
    }

    private var autoDone: [(title: String, bytes: UInt64)] = []
    private var autoDoneFlush: DispatchWorkItem?

    private func autoClose(_ t: Thing, early: Bool) {
        guard let cat = AutoCategory.of(t), let setting = prefs.autoLimit(cat), let i = latest?.insights[t.id],
              let limit = Automation.limit(setting: setting, insight: i) else { return }
        pendingAuto[t.id] = nil
        let key = "auto:\(t.id)"
        let bytes = t.memory
        act(on: t.id, key: key, gate: .automatic(idleLimit: early ? 0 : limit), label: t.title, quiet: true) { [weak self] ok in
            guard let self else { return }
            self.autoLog.insert((Date(), ok ? "Closed \(t.title) (\(Format.bytes(bytes)))" : "Left \(t.title) running"), at: 0)
            if self.autoLog.count > 12 { self.autoLog.removeLast() }
            if ok { self.autoDone.append((t.title, bytes)) }
            // One summary once the batch settles.
            self.autoDoneFlush?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flushAutoDone() }
            self.autoDoneFlush = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        }
    }

    private func flushAutoDone() {
        guard !autoDone.isEmpty else { return }
        let total = autoDone.reduce(UInt64(0)) { $0 + $1.bytes }
        let title = autoDone.count == 1 ? "Closed \(autoDone[0].title)" : "Closed \(autoDone.count) idle things"
        let body = (autoDone.count == 1 ? "It went unused past its limit." : autoDone.prefix(3).map { "“\($0.title)”" }.joined(separator: ", ") + (autoDone.count > 3 ? " and \(autoDone.count - 3) more." : "."))
            + " Freed \(Format.bytes(total))."
        notifier.postAuto(id: "autodone:\(Int(Date().timeIntervalSince1970))", title: title, body: body, headsUp: false)
        flash(title + ", freed \(Format.bytes(total)).")
        autoDone = []
    }

    func keepRunning(_ thingID: String, announce: Bool = true) {
        prefs.keepRunning(thingID)
        if let t = latest?.things.first(where: { $0.id == thingID }) { engine.queue.async { [engine] in engine.noteKept(t) } }
        pendingAuto[thingID] = nil
        notifier.withdraw(["auto:\(thingID)"])
        let title = latest?.things.first { $0.id == thingID }?.title ?? "It"
        if announce { flash("\(title) stays running for the next 24 hours.") }
    }

    // MARK: - Snooze, ignore, toast

    func snooze(_ id: String, for seconds: TimeInterval) {
        prefs.snooze(id, until: Date().addingTimeInterval(seconds))
        notifier.withdraw([id])
        suggestions.removeAll { $0.id == id }
    }

    func snoozeUntilTomorrow(_ id: String) {
        let cal = Calendar.current
        let tomorrow = cal.date(bySettingHour: 8, minute: 0, second: 0,
                                of: cal.date(byAdding: .day, value: 1, to: Date())!) ?? Date().addingTimeInterval(86400)
        snooze(id, for: tomorrow.timeIntervalSinceNow)
    }

    func ignore(_ s: Suggestion) {
        prefs.ignore(s.id, label: s.ignoreLabel)
        notifier.withdraw([s.id])
        suggestions.removeAll { $0.id == s.id }
    }

    func flash(_ message: String) {
        guard !message.isEmpty else { return }
        toast = message
        let m = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
            if self?.toast == m { self?.toast = nil }
        }
    }

    func forgetHabits() {
        engine.queue.async { [engine] in engine.forgetHabits() }
        flash("Slop Cleaner forgot what it learned. Smart times start fresh.")
    }

    /// What following every suggestion would free.
    var potentialSavings: (cpu: Double, memory: UInt64) {
        guard let tick = latest else { return (0, 0) }
        var ids = Set<String>()
        for s in suggestions where s.action.isDestructive && s.blockedNote == nil {
            if case .sweep(let list) = s.action { ids.formUnion(list) } else if let id = s.thingID { ids.insert(id) }
        }
        let ts = tick.things.filter { ids.contains($0.id) }
        return (ts.reduce(0) { $0 + $1.cpu }, ts.reduce(0) { $0 + $1.memory })
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

// MARK: - Demo data (only for README screenshots: `scripts/snapshot.sh out.png demo`)

extension AppState {
    func loadDemo(tab: PopoverTab) {
        demo = true
        let now = Date()
        func proc(_ pid: Int32, _ name: String, _ path: String, cpu: Double, mem: Double, hours: Double) -> ProcessSnapshot {
            ProcessSnapshot(pid: pid, ppid: 1, uid: getuid(), name: name, path: path, args: [], cwd: nil,
                            startTime: now.addingTimeInterval(-hours * 3600), cpu: cpu, memory: UInt64(mem * 1_073_741_824))
        }
        let browser = ["/Applications/Google Chrome.app", "/Applications/Safari.app"].first { FileManager.default.fileExists(atPath: $0) }
            ?? "/System/Applications/Safari.app"
        let emu = Thing(id: "demo-emu", kind: .androidEmulator(serial: "emulator-5554", avd: "Pixel_8_API_35"),
                        title: "Pixel 8 API 35 emulator", subtitle: "emulator-5554",
                        processes: [proc(4101, "qemu-system-aarch64", "/sdk/qemu", cpu: 1130, mem: 4.2, hours: 44)])
        let web = Thing(id: "demo-web", kind: .app(bundlePath: browser), title: (browser as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""),
                        subtitle: "38 processes", processes: [proc(4102, "browser", browser + "/Contents/MacOS/x", cpu: 85, mem: 9.6, hours: 30)])
        let vite = Thing(id: "demo-vite", kind: .devServer, title: "Vite dev server", subtitle: "in web/app",
                         processes: [proc(4103, "node", "/opt/homebrew/bin/node", cpu: 4, mem: 1.4, hours: 75)])
        let session = Thing(id: "demo-session", kind: .claudeSession, title: "Fix the login redirect", subtitle: "Claude Code · ~/projects",
                            processes: [proc(4104, "claude", "/x/claude", cpu: 0, mem: 0.85, hours: 52)])
        let sim = Thing(id: "demo-sim", kind: .iosSimulator(udid: "8F1C2D3E-4A5B-4C6D-8E7F-901234567890", name: "iPhone 17"),
                        title: "iPhone 17", subtitle: "Simulator · 8F1C2D3E",
                        processes: [proc(4105, "launchd_sim", "/x/launchd_sim", cpu: 22, mem: 5.1, hours: 6)])
        func insight(_ text: String, idle: TimeInterval, inUse: Bool = false, verdict: Safety.Verdict = .safe,
                     reasons: [String] = [], effect: String, smart: TimeInterval? = nil, why: String = "") -> Insight {
            var i = Insight(usage: Usage(text: text, idleFor: idle, inUseNow: inUse, exact: true),
                            safety: Safety(verdict: verdict, reasons: reasons, notes: [], effect: effect, action: .none, actionTitle: "Quit"))
            if let smart { i.smart = UsageMemory.Pick(seconds: smart, reason: why, learned: true) }
            return i
        }
        things = [emu, web, sim, vite, session]
        insights = [
            emu.id: insight("Last driven 44 h ago", idle: 44 * 3600, effect: "Saves a snapshot and shuts it down.",
                            smart: 3600, why: "Your breaks with it are usually under 50 min"),
            web.id: insight("In use now", idle: 0, inUse: true, verdict: .blocked, reasons: ["You're using it right now."], effect: ""),
            sim.id: insight("Being driven right now", idle: 0, inUse: true, verdict: .blocked, reasons: ["Something is driving it right now."],
                            effect: "", smart: 2 * 3600, why: "Your breaks with it are usually under 1 h 40 min"),
            vite.id: insight("Last client 2 days 3 h ago", idle: 51 * 3600, effect: "Stops the server.", smart: 3 * 3600,
                             why: "Still learning your habits"),
            session.id: insight("Last activity 2 days 4 h ago", idle: 52 * 3600, effect: "Stops its background process.", smart: 24 * 3600,
                                why: "Sessions get a full day"),
        ]
        thingSeries = [emu.id: (0..<60).map { _ in Double.random(in: 1080...1160) },
                       web.id: (0..<60).map { _ in Double.random(in: 40...120) },
                       sim.id: (0..<60).map { _ in Double.random(in: 10...35) }]
        var s = SystemStats()
        s.cpuFraction = 0.64; s.memoryUsed = UInt64(71 * 1_073_741_824.0); s.swapUsed = UInt64(1.2 * 1_073_741_824.0)
        s.thermal = .fair; s.processCount = 1_842
        stats = s
        systemSeries = (0..<120).map { i in 0.55 + 0.1 * sin(Double(i) / 9) + Double.random(in: -0.03...0.03) }
        lastUpdate = now
        var pile = Suggestion(id: "claude-pile", thingID: nil, severity: .suggest, symbol: "terminal",
                              title: "6 Claude Code sessions haven't been used in over 24 h",
                              detail: "Each keeps a background process holding memory. Stopping them frees 5.3 GB. The sessions stay in the Claude app with all their history, and start again when you open one.",
                              evidence: ["6 of 9 idle", "5.3 GB"], action: .sweep(ids: []), actionTitle: "Stop 6 idle sessions",
                              notify: true, ignoreLabel: "Idle Claude sessions")
        pile.items = ["“Fix the login redirect” · idle 2 days 4 h · 870 MB", "“Write release notes” · idle 2 days 1 h · 910 MB",
                      "“Profile the image cache” · idle 1 day 20 h · 880 MB", "and 3 more"]
        suggestions = [
            Suggestion(id: "idle-emulator:demo", thingID: emu.id, severity: .urgent, symbol: "smartphone",
                       title: "Pixel 8 API 35 emulator is using 11 cores",
                       detail: "Running 44 h. Last driven 44 h ago. Shutting down saves its snapshot.",
                       evidence: ["11.3 cores", "4.2 GB", "up 44 h", "nobody driving"],
                       action: .stopEmulator(serial: "emulator-5554"), actionTitle: "Shut down", notify: true, ignoreLabel: "demo"),
            pile,
            Suggestion(id: "didnt-quit:Preview", thingID: nil, severity: .suggest, symbol: "exclamationmark.bubble",
                       title: "Preview didn't quit",
                       detail: "Slop Cleaner asked it to quit 2 min ago. It's probably waiting on you (unsaved work, a dialog), or it may be stuck. Slop Cleaner never force-quits apps, so it's your call.",
                       evidence: ["asked 2 min ago", "still open"], action: .showApp(pid: 1), actionTitle: "Show it",
                       notify: false, ignoreLabel: "demo"),
            Suggestion(id: "stale:demo", thingID: vite.id, severity: .info, symbol: "server.rack",
                       title: "Vite dev server has been running 3 days 3 h",
                       detail: "Running for 3 days 3 h in web/app. Last client 2 days 3 h ago. Quitting frees 1.4 GB. Started from your terminal (Ghostty): npm run dev.",
                       evidence: ["0.0 cores", "1.4 GB", "up 3 days 3 h"], action: .terminate(pid: 1, start: now),
                       actionTitle: "Quit it", notify: false, ignoreLabel: "demo"),
        ]
        pendingAuto = [vite.id: now.addingTimeInterval(4 * 60)]
        autoLog = [(now.addingTimeInterval(-1800), "Closed 4 idle things (3.9 GB)"),
                   (now.addingTimeInterval(-7200), "Closed iPhone 16 simulator (5.0 GB)")]
        self.tab = tab
        uiQuery = ""
        uiExpanded = tab == .now ? [] : []
    }

    func exitDemo() {
        demo = false
        refresh()
    }
}
