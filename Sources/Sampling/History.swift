import Foundation

/// Rolling memory: the last 30 minutes of CPU per thing, plus when each thing was last used.
///
/// "Last used" depends on the kind of thing: last in front (apps), last client connected (servers),
/// last driven by automation (emulators, simulators), last busy (everything else).
/// Saved to disk, so a quick restart of Watcher keeps it. After a longer gap it starts fresh,
/// because Watcher can't know what happened while it wasn't watching.
final class History {
    struct Point { let t: Date; let cpu: Double; let mem: UInt64 }

    private(set) var series: [String: [Point]] = [:]
    private(set) var firstSeen: [String: Date] = [:]
    private(set) var lastBusy: [String: Date] = [:]
    private(set) var lastDriven: [String: Date] = [:]
    private(set) var lastFront: [String: Date] = [:]
    private(set) var lastClient: [String: Date] = [:]
    private(set) var system: [(t: Date, cpu: Double)] = []
    private(set) var peakToday: (cpu: Double, at: Date)? = nil

    let keep: TimeInterval
    let busyCPU: Double

    init(keep: TimeInterval = 30 * 60, busyCPU: Double = 5) {
        self.keep = keep
        self.busyCPU = busyCPU
    }

    func record(things: [Thing], systemCPU: Double, driven: Set<String>, frontmostPID: Int32?, at now: Date) {
        let cutoff = now.addingTimeInterval(-keep)
        var alive = Set<String>()
        for t in things {
            alive.insert(t.id)
            if firstSeen[t.id] == nil { firstSeen[t.id] = now }
            let cpu = t.cpu
            if cpu >= busyCPU { lastBusy[t.id] = now }
            if !t.clients.isEmpty { lastClient[t.id] = now }
            if let f = frontmostPID, t.processes.contains(where: { $0.pid == f }) { lastFront[t.id] = now }
            var s = series[t.id] ?? []
            s.append(Point(t: now, cpu: cpu, mem: t.memory))
            if let i = s.firstIndex(where: { $0.t >= cutoff }), i > 0 { s.removeFirst(i) }
            series[t.id] = s
        }
        for id in Array(firstSeen.keys) where !alive.contains(id) {
            series[id] = nil; firstSeen[id] = nil; lastBusy[id] = nil; lastFront[id] = nil; lastClient[id] = nil
        }
        for d in driven { lastDriven[d] = now }

        system.append((now, systemCPU))
        if let i = system.firstIndex(where: { $0.t >= cutoff }), i > 0 { system.removeFirst(i) }

        if let p = peakToday, Calendar.current.isDate(p.at, inSameDayAs: now), p.cpu >= systemCPU {
            // keep today's peak
        } else {
            peakToday = (systemCPU, now)
        }
    }

    /// Average CPU over the window, or nil when there aren't samples covering 80% of it.
    func average(_ id: String, window: TimeInterval, now: Date) -> Double? {
        guard let s = series[id], let first = s.first, now.timeIntervalSince(first.t) >= window * 0.8 else { return nil }
        let from = now.addingTimeInterval(-window)
        var sum = 0.0, n = 0
        for p in s.reversed() {
            if p.t < from { break }
            sum += p.cpu; n += 1
        }
        return n == 0 ? nil : sum / Double(n)
    }

    func observed(_ id: String, now: Date) -> TimeInterval {
        guard let f = firstSeen[id] else { return 0 }
        return now.timeIntervalSince(f)
    }

    /// Seconds since anything drove this device (adb client, maestro, xcodebuild...). nil = not seen while watching.
    func sinceDriven(_ device: String, now: Date) -> TimeInterval? {
        let times = [lastDriven[device], lastDriven[device.hasPrefix("emulator-") ? "*android" : "*ios"]].compactMap { $0 }
        guard let latest = times.max() else { return nil }
        return now.timeIntervalSince(latest)
    }

    func cpuSeries(_ id: String) -> [Double] { series[id]?.map(\.cpu) ?? [] }

    // MARK: - Saving

    private struct Saved: Codable {
        var savedAt: Date
        var firstSeen: [String: Date]
        var lastBusy: [String: Date]
        var lastDriven: [String: Date]
        var lastFront: [String: Date]
        var lastClient: [String: Date]
    }

    func save(to url: URL, now: Date = Date()) {
        let s = Saved(savedAt: now, firstSeen: firstSeen, lastBusy: lastBusy, lastDriven: lastDriven,
                      lastFront: lastFront, lastClient: lastClient)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }

    /// Restores only if the last save was recent (Watcher restarted, not stopped for a while).
    func load(from url: URL, now: Date = Date(), maxGap: TimeInterval = 10 * 60) {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Saved.self, from: data),
              now.timeIntervalSince(s.savedAt) <= maxGap else { return }
        firstSeen = s.firstSeen; lastBusy = s.lastBusy; lastDriven = s.lastDriven
        lastFront = s.lastFront; lastClient = s.lastClient
    }

    // MARK: - Test hooks

    func seed(id: String, cpu: Double, mem: UInt64 = 0, minutes: Double, step: TimeInterval = 5, endingAt now: Date) {
        let start = now.addingTimeInterval(-minutes * 60)
        firstSeen[id] = start
        var s: [Point] = []
        var t = start
        while t <= now { s.append(Point(t: t, cpu: cpu, mem: mem)); t.addTimeInterval(step) }
        series[id] = s
        if cpu >= busyCPU { lastBusy[id] = now }
    }

    func markDriven(_ device: String, at: Date) { lastDriven[device] = at }
    func markFront(_ id: String, at: Date) { lastFront[id] = at }
    func markClient(_ id: String, at: Date) { lastClient[id] = at }
    func markBusy(_ id: String, at: Date) { lastBusy[id] = at }
}
