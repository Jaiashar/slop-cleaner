import Foundation

/// Where the load is coming from, in words that answer "why are my fans loud?".
enum HeatSource: Int, CaseIterable {
    case work, macOS, apps, other

    var title: String {
        switch self {
        case .work: return "Work in progress"
        case .macOS: return "macOS background jobs"
        case .apps: return "Your apps"
        case .other: return "Other"
        }
    }

    var note: String {
        switch self {
        case .work: return "agent sessions, builds, tests and devices in use"
        case .macOS: return "macOS's own jobs; they finish on their own"
        case .apps: return "apps you have open"
        case .other: return "everything else"
        }
    }

    var symbol: String {
        switch self {
        case .work: return "hammer"
        case .macOS: return "apple.logo"
        case .apps: return "macwindow"
        case .other: return "ellipsis.circle"
        }
    }

    static func of(_ t: Thing) -> HeatSource {
        switch t.kind {
        case .claudeSession, .testRun, .buildDaemon, .devServer, .androidEmulator, .iosSimulator:
            return .work
        case .app:
            return .apps
        case .system:
            return .macOS
        case .process:
            if t.ownerID != nil || (t.origin ?? "").contains("Claude session") || (t.origin ?? "").hasPrefix("Started from your terminal") {
                return .work
            }
            let path = t.root.path
            if Rules.macOSJobs[t.root.name] != nil || path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/")
                || path.hasPrefix("/usr/sbin/") || path.hasPrefix("/Library/Apple/") {
                return .macOS
            }
            return .other
        }
    }

    struct Row: Identifiable {
        let source: HeatSource
        let cpu: Double
        let top: [String]
        var id: Int { source.rawValue }
    }

    /// Load grouped by source, biggest first, with the top two names in each.
    static func breakdown(_ things: [Thing], cpu: (Thing) -> Double) -> [Row] {
        var groups: [HeatSource: [(Thing, Double)]] = [:]
        for t in things { groups[of(t), default: []].append((t, cpu(t))) }
        return groups.map { source, items in
            let sorted = items.sorted { $0.1 > $1.1 }
            let top = sorted.prefix(2).filter { $0.1 >= 10 }.map { "\(friendlyName($0.0)) \(Format.cores($0.1))" }
            return Row(source: source, cpu: items.reduce(0) { $0 + $1.1 }, top: top)
        }
        .filter { $0.cpu >= 15 }
        .sorted { $0.cpu > $1.cpu }
    }

    static func friendlyName(_ t: Thing) -> String {
        Rules.macOSJobs[t.root.name]?.name ?? t.title
    }
}
