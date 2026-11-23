import Foundation

/// Everything that runs off the main thread: sampling, grouping, connections, history, rules.
/// Only ever touched from `queue`.
final class Engine: @unchecked Sendable {
    struct Tick {
        let stats: SystemStats
        let things: [Thing]
        let insights: [String: Insight]
        let suggestions: [Suggestion]
        let systemSeries: [Double]
        let peak: (cpu: Double, at: Date)?
        let thingSeries: [String: [Double]]
        let at: Date
    }

    let queue = DispatchQueue(label: "watcher.engine", qos: .utility)
    private let processes = ProcessSampler()
    private let system = SystemSampler()
    private let history = History()
    private let sims = SimulatorNames()
    private let locks = QALocks()
    private let sessionStore = ClaudeSessionStore()
    let usage = UsageMemory()
    private var tickCount = 0
    private var listenByPid: [Int32: [UInt16]] = [:]
    private var clientsByPid: [Int32: [SocketScanner.Client]] = [:]
    private let myUID = getuid()

    private lazy var historyURL: URL = ActionRunner.logURL.deletingLastPathComponent().appendingPathComponent("history.json")
    private lazy var usageURL: URL = ActionRunner.logURL.deletingLastPathComponent().appendingPathComponent("habits.json")

    init() {
        queue.async { [self] in
            history.load(from: historyURL)
            usage.load(from: usageURL)
        }
    }

    /// `freshConnections` re-reads every socket now (used right before acting on something).
    private let origins = OriginCache()

    func tick(thresholds: Thresholds, frontmostPID: Int32?, freshConnections: Bool = false, detail: Bool = false,
              query: String = "", focusID: String? = nil, now: Date = Date()) -> Tick {
        tickCount += 1
        let procs = processes.sample(now: now)
        let stats = system.sample(processCount: procs.count)

        let booted = Set(procs.filter { $0.name == "launchd_sim" }
            .compactMap { Classifier.firstUUID(in: $0.args.joined(separator: " ")) })
        sims.refreshIfNeeded(booted: booted)

        let sessionIDs = Set(procs.compactMap(\.hostSessionID))
        var c = Classifier.classify(procs, simNames: sims.names, sessions: sessionStore.records(for: sessionIDs, now: now),
                                   origins: origins)

        // Connections: every 30 s, or fresh right before acting on anything.
        if freshConnections || tickCount % 6 == 1 {
            let mine = procs.filter { $0.uid == myUID }.map(\.pid)
            let found = SocketScanner.clients(of: SocketScanner.scan(pids: mine))
            listenByPid = found.listen
            clientsByPid = found.clients
        }
        Engine.attachConnections(&c.things, procs: procs, listen: listenByPid, clients: clientsByPid)

        history.record(things: c.things, systemCPU: stats.cpuFraction, driven: c.driven, frontmostPID: frontmostPID, at: now)
        if tickCount % 12 == 0 { saveHistory(now: now) }

        let ctx = RuleContext(things: c.things, stats: stats, history: history, now: now, thresholds: thresholds,
                              driven: c.driven, locks: { [locks] keys in locks.lock(for: keys, now: now) },
                              frontmostPID: frontmostPID)
        let src = InsightSource(ctx)
        src.enrich = { [usage, history] t, i in
            guard AutoCategory.of(t) != nil else { return }
            usage.observe(t, inUseNow: i.usage.inUseNow, now: now)
            i.smart = usage.pick(for: t, recentCPU: history.average(t.id, window: 10 * 60, now: now) ?? t.cpu, now: now)
        }
        // Always: everything Automate could close (so it keeps learning). Everything else only when needed.
        for t in c.things where AutoCategory.of(t) != nil { _ = src[t] }
        let suggestions = Rules.evaluate(ctx, src)
        if detail {
            // Only what the popover can show: the top rows by CPU and by memory, plus search matches.
            for t in c.things.sorted(by: { $0.cpu > $1.cpu }).prefix(40) { _ = src[t] }
            for t in c.things.sorted(by: { $0.memory > $1.memory }).prefix(40) { _ = src[t] }
            if !query.isEmpty {
                for t in c.things where t.title.localizedCaseInsensitiveContains(query)
                    || t.subtitle.localizedCaseInsensitiveContains(query)
                    || t.listenPorts.contains(where: { String($0) == query })
                    || t.processes.contains(where: { $0.name.localizedCaseInsensitiveContains(query) || String($0.pid) == query }) {
                    _ = src[t]
                }
            }
        }
        if let f = focusID, let t = c.things.first(where: { $0.id == f }) { _ = src[t] }
        let insights = src.cache

        let sorted = c.things.sorted { $0.cpu > $1.cpu }
        var series: [String: [Double]] = [:]
        for t in sorted.prefix(40) { series[t.id] = Array(history.cpuSeries(t.id).suffix(120)) }
        return Tick(stats: stats, things: sorted, insights: insights, suggestions: suggestions,
                    systemSeries: history.system.suffix(120).map(\.cpu), peak: history.peakToday,
                    thingSeries: series, at: now)
    }

    func saveHistory(now: Date = Date()) {
        history.save(to: historyURL, now: now)
        usage.save(to: usageURL, now: now)
    }

    /// Called (on `queue`) after Watcher closed something, or you said to keep it.
    func noteClosed(_ t: Thing) { usage.markClosed(t); saveHistory() }
    func noteKept(_ t: Thing) { usage.markKept(t); saveHistory() }
    func forgetHabits() { usage.forget(); saveHistory() }

    /// Fills in each thing's listening ports and who is connected to it, by name.
    static func attachConnections(_ things: inout [Thing], procs: [ProcessSnapshot], listen: [Int32: [UInt16]],
                                  clients: [Int32: [SocketScanner.Client]], selfPID: Int32 = getpid()) {
        var thingOf: [Int32: Int] = [:]
        for (i, t) in things.enumerated() { for p in t.processes { thingOf[p.pid] = i } }
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        for (i, t) in things.enumerated() {
            let isEmulator: Bool = { if case .androidEmulator = t.kind { return true }; return false }()
            var ports = Set<UInt16>()
            var labels: [String] = []
            for p in t.processes {
                ports.formUnion(listen[p.pid] ?? [])
                for client in clients[p.pid] ?? [] {
                    if let cp = client.pid {
                        guard let ci = thingOf[cp], ci != i else { continue }   // talking to itself
                        // adb's background server stays connected to every running emulator for as long as
                        // it runs. That connection is plumbing, not someone using it; real use shows up as
                        // an adb command, Maestro or a test run driving it (see Classifier.drivenDevices).
                        if isEmulator, let q = byPid[cp], Classifier.isAdbServer(q) { continue }
                        let owner = things[ci]
                        let name = byPid[cp]?.name ?? "pid \(cp)"
                        if owner.processes.contains(where: { $0.pid == selfPID }) { continue }
                        switch owner.kind {
                        case .app: labels.append(owner.title)
                        case .iosSimulator, .androidEmulator, .claudeSession:
                            labels.append(name == owner.title ? name : "\(name) in \(owner.title)")
                        default: labels.append(owner.title)
                        }
                    } else if let r = client.remote {
                        labels.append("a device at \(r)")
                    }
                }
            }
            things[i].listenPorts = ports.sorted()
            things[i].clients = Array(NSOrderedSet(array: labels)) as? [String] ?? labels
        }
    }
}
