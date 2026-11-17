import Foundation

/// Optional: a lock on a shared test device, so Slop Cleaner leaves it alone while someone holds it.
/// A lock is a folder `<lock folder>/<device>/` with a file `owner` whose first line names the holder
/// ("<who> | since <time>"). Device = adb serial, AVD name, simulator UDID or simulator name.
/// Set the folder with: defaults write io.github.jaiashar.slopcleaner qaLockFolder ~/path/to/locks
struct QALock: Equatable {
    let holder: String
    let since: Date
    let stale: Bool
}

struct QALocks {
    var root: String = UserDefaults.standard.string(forKey: "qaLockFolder")
        .map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory() + "/.qa-locks"
    var staleAfter: TimeInterval = 60 * 60

    /// The first live lock under any of the given device names (serial, AVD, UDID or simulator name).
    func lock(for keys: [String], now: Date = Date()) -> QALock? {
        let fm = FileManager.default
        for key in keys where !key.isEmpty {
            let dir = root + "/" + key
            guard let owner = try? String(contentsOfFile: dir + "/owner", encoding: .utf8) else { continue }
            let mtime = (try? fm.attributesOfItem(atPath: dir)[.modificationDate] as? Date) ?? now
            let holder = owner.components(separatedBy: " | since").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? owner
            return QALock(holder: holder, since: mtime, stale: now.timeIntervalSince(mtime) > staleAfter)
        }
        return nil
    }
}

/// Booted simulator names, re-read only when the set of booted UDIDs changes.
final class SimulatorNames {
    private var known: Set<String> = []
    private(set) var names: [String: String] = [:]

    func refreshIfNeeded(booted udids: Set<String>) {
        guard udids != known else { return }
        known = udids
        guard !udids.isEmpty,
              let out = Shell.run("/usr/bin/xcrun", ["simctl", "list", "-j", "devices", "booted"], timeout: 10)?.output,
              let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else { return }
        var map: [String: String] = [:]
        for list in devices.values {
            for d in list {
                if let u = d["udid"] as? String, let n = d["name"] as? String { map[u.uppercased()] = n }
            }
        }
        names = map
    }
}
