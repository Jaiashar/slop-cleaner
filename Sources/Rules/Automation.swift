import Foundation

/// What Automate may close on its own. Only kinds that are safe to stop and easy to bring back:
/// never apps (unsaved work), never Claude sessions, never system processes.
enum AutoCategory: String, CaseIterable, Identifiable {
    case emulators, simulators, devServers, buildDaemons, claudeSessions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .emulators: return "Android emulators"
        case .simulators: return "iOS simulators"
        case .devServers: return "Dev servers"
        case .buildDaemons: return "Gradle and Kotlin daemons"
        case .claudeSessions: return "Idle Claude Code sessions"
        }
    }

    var detail: String {
        switch self {
        case .emulators: return "Shuts down when nothing has driven it. Its snapshot is saved."
        case .simulators: return "Shuts down when nothing has driven it. Apps and data stay."
        case .devServers: return "Quits Expo, Metro, Vite and similar when nothing has connected to them."
        case .buildDaemons: return "Stops build daemons that have sat idle. The next build starts a new one."
        case .claudeSessions: return "Stops the background process of sessions you haven't touched. They stay in Claude and start again when you open them."
        }
    }

    var symbol: String {
        switch self {
        case .emulators: return "smartphone"
        case .simulators: return "iphone"
        case .devServers: return "server.rack"
        case .buildDaemons: return "hammer"
        case .claudeSessions: return "terminal"
        }
    }

    static func of(_ t: Thing) -> AutoCategory? {
        switch t.kind {
        case .androidEmulator: return .emulators
        case .iosSimulator: return .simulators
        case .devServer: return .devServers
        case .buildDaemon: return .buildDaemons
        case .claudeSession: return .claudeSessions
        default: return nil
        }
    }

    /// -1 = Smart (Watcher picks per item from your habits).
    static let smart: Double = -1
    static let choices: [Double] = [smart, 0.5, 1, 2, 4, 8, 12, 24]
}

enum Automation {
    static let smart = AutoCategory.smart

    /// Heads-up before closing, so there's time to say "keep it".
    static let warning: TimeInterval = 5 * 60

    /// Closing is allowed only when it's safe right now and it has gone unused for the whole limit.
    static func eligible(_ i: Insight, idleLimit: TimeInterval) -> Bool {
        i.safety.verdict == .safe && !i.usage.inUseNow && i.usage.idleFor >= idleLimit && i.safety.action.isDestructive
    }

    static func hoursText(_ h: Double) -> String {
        if h < 0 { return "Smart" }
        return h < 1 ? "\(Int(h * 60)) min" : h == 1 ? "1 hour" : "\(Int(h)) hours"
    }

    /// The limit that applies to this item: your fixed choice, or Smart's pick for it.
    static func limit(setting h: Double, insight: Insight) -> TimeInterval? {
        h < 0 ? insight.smart?.seconds : h * 3600
    }
}
