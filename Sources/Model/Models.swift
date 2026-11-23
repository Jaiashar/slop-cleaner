import Foundation

/// One process at one moment. `cpu` is a percent of one core (100 = one full core).
struct ProcessSnapshot: Hashable {
    let pid: Int32
    let ppid: Int32
    let uid: UInt32
    let name: String
    let path: String
    let args: [String]
    let cwd: String?
    let startTime: Date
    var cpu: Double
    var memory: UInt64
    /// For Claude Code sessions run by the Claude app: its session id (CLAUDE_CODE_HOST_SESSION_ID).
    var hostSessionID: String? = nil

    /// Stable across samples and safe against pid reuse.
    var key: String { "\(pid)@\(Int(startTime.timeIntervalSince1970 * 1000))" }
}

enum ThingKind: Hashable {
    case androidEmulator(serial: String, avd: String)
    case iosSimulator(udid: String, name: String)
    case claudeSession
    case devServer
    case testRun
    case buildDaemon
    case app(bundlePath: String)
    case system
    case process

    var label: String {
        switch self {
        case .androidEmulator: return "Android emulator"
        case .iosSimulator: return "iOS simulator"
        case .claudeSession: return "Claude Code session"
        case .devServer: return "Dev server"
        case .testRun: return "Test or build run"
        case .buildDaemon: return "Build daemon"
        case .app: return "App"
        case .system: return "System"
        case .process: return "Process"
        }
    }
}

/// Something a person recognizes: an app, an emulator, a Claude session, a dev server.
struct Thing: Identifiable, Hashable {
    let id: String
    let kind: ThingKind
    var title: String
    var subtitle: String
    var processes: [ProcessSnapshot]
    /// For tools started by a Claude session: which one.
    var ownerLabel: String? = nil
    /// The Claude session that started it, if any.
    var ownerID: String? = nil
    /// Where it came from, when we can tell: "Started from your terminal (Ghostty): make dev".
    var origin: String? = nil
    /// The open app that started it, if one did (not a command or a Claude session).
    var originApp: String? = nil
    /// TCP ports it listens on, and who is connected right now (filled in by the Engine).
    var listenPorts: [UInt16] = []
    var clients: [String] = []
    /// Last use reported by its own app (Claude's session record), when there is one.
    var externalLastUse: Date? = nil

    var cpu: Double { processes.reduce(0) { $0 + $1.cpu } }
    var memory: UInt64 { processes.reduce(0) { $0 + $1.memory } }
    var startedAt: Date { processes.map(\.startTime).min() ?? Date() }
    var root: ProcessSnapshot { processes[0] }
    var hottest: ProcessSnapshot { processes.max(by: { $0.cpu < $1.cpu }) ?? processes[0] }

    var symbol: String {
        switch kind {
        case .androidEmulator: return "smartphone"
        case .iosSimulator: return "iphone"
        case .claudeSession: return "terminal"
        case .devServer: return "server.rack"
        case .testRun: return "testtube.2"
        case .buildDaemon: return "hammer"
        case .app: return "app"
        case .system: return "gearshape.2"
        case .process: return "cpu"
        }
    }
}

struct SystemStats: Equatable {
    var cpuFraction: Double = 0        // 0...1 of the whole machine
    var cores: Int = ProcessInfo.processInfo.activeProcessorCount
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
    var pressureLevel: Int = 1
    var swapUsed: UInt64 = 0
    var thermal: ProcessInfo.ThermalState = .nominal
    var processCount: Int = 0

    var pressureText: String {
        switch pressureLevel {
        case 4...: return "Critical"
        case 2...: return "Tight"
        default: return "OK"
        }
    }

    var thermalText: String {
        switch thermal {
        case .nominal: return "Cool"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Very hot"
        @unknown default: return "Unknown"
        }
    }
}

enum Format {
    static func cores(_ cpu: Double) -> String {
        let c = cpu / 100
        if c >= 9.95 { return "\(Int(c.rounded())) cores" }
        if c >= 0.95 && c < 1.05 { return "1 core" }
        return String(format: "%.1f cores", c)
    }

    /// Plain-language core count for sentences: "11 cores", "a full core", "half a core".
    static func coresPhrase(_ cpu: Double) -> String {
        let c = cpu / 100
        if c >= 1.5 { return "\(Int(c.rounded())) cores" }
        if c >= 0.85 { return "a full core" }
        if c >= 0.35 { return "half a core" }
        return "a little CPU"
    }

    static func bytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 10 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(b) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m < 1 { return "under a minute" }
        if m < 60 { return "\(m) min" }
        let h = m / 60
        if h < 10 { return m % 60 == 0 ? "\(h) h" : "\(h) h \(m % 60) min" }
        if h < 48 { return "\(h) h" }
        let d = h / 24, rest = h % 24
        return rest == 0 ? "\(d) days" : "\(d) days \(rest) h"
    }

    static func ago(_ t: TimeInterval) -> String {
        t < 60 ? "just now" : "\(duration(t)) ago"
    }
}
