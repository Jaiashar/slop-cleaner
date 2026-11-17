import Foundation
import ServiceManagement

/// User settings, saved in UserDefaults.
final class Preferences: ObservableObject {
    private let d = UserDefaults.standard

    @Published var sensitivity: Sensitivity { didSet { d.set(sensitivity.rawValue, forKey: "sensitivity") } }
    @Published var notificationsOn: Bool { didSet { d.set(notificationsOn, forKey: "notificationsOn") } }
    @Published var quietHoursOn: Bool { didSet { d.set(quietHoursOn, forKey: "quietHoursOn") } }
    @Published var quietStart: Int { didSet { d.set(quietStart, forKey: "quietStart") } }
    @Published var quietEnd: Int { didSet { d.set(quietEnd, forKey: "quietEnd") } }
    /// Suggestion id → what it was about, for the settings list.
    @Published var ignored: [String: String] { didSet { d.set(ignored, forKey: "ignored") } }
    @Published var snoozes: [String: Date] { didSet { d.set(snoozes, forKey: "snoozes") } }
    /// Automate: category → hours unused before closing. Missing = off.
    @Published var autoHours: [String: Double] { didSet { d.set(autoHours, forKey: "autoHours") } }
    /// Things you said to keep running: thing id → until.
    @Published var autoKeep: [String: Date] { didSet { d.set(autoKeep, forKey: "autoKeep") } }

    init() {
        sensitivity = Sensitivity(rawValue: d.string(forKey: "sensitivity") ?? "") ?? .normal
        notificationsOn = d.object(forKey: "notificationsOn") as? Bool ?? true
        quietHoursOn = d.object(forKey: "quietHoursOn") as? Bool ?? false
        quietStart = d.object(forKey: "quietStart") as? Int ?? 23
        quietEnd = d.object(forKey: "quietEnd") as? Int ?? 8
        ignored = d.dictionary(forKey: "ignored") as? [String: String] ?? [:]
        let saved = d.dictionary(forKey: "snoozes") as? [String: Date] ?? [:]
        snoozes = saved.filter { $0.value > Date() }
        var hours = d.dictionary(forKey: "autoHours") as? [String: Double] ?? [:]
        // One time: 2 hours was the old built-in default, not a choice. Move those rules to Smart.
        if !d.bool(forKey: "migratedToSmart") {
            hours = hours.mapValues { $0 == 2 ? AutoCategory.smart : $0 }
            d.set(hours, forKey: "autoHours")
            d.set(true, forKey: "migratedToSmart")
        }
        autoHours = hours
        let keep = d.dictionary(forKey: "autoKeep") as? [String: Date] ?? [:]
        autoKeep = keep.filter { $0.value > Date() }
    }

    // MARK: Cleaned today (count, bytes, CPU), kept per day.
    @Published private(set) var cleaned: [String: [Double]] = UserDefaults.standard.dictionary(forKey: "cleaned") as? [String: [Double]] ?? [:]

    private static let dayKey: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    func recordCleaned(bytes: UInt64, cpu: Double, now: Date = Date()) {
        let k = Self.dayKey.string(from: now)
        var v = cleaned[k] ?? [0, 0, 0]
        v[0] += 1; v[1] += Double(bytes); v[2] += cpu
        cleaned[k] = v
        cleaned = cleaned.filter { $0.key >= Self.dayKey.string(from: now.addingTimeInterval(-30 * 86400)) }
        d.set(cleaned, forKey: "cleaned")
    }

    func cleanedOn(_ date: Date = Date()) -> (count: Int, bytes: UInt64, cpu: Double) {
        let v = cleaned[Self.dayKey.string(from: date)] ?? [0, 0, 0]
        return (Int(v[0]), UInt64(v[1]), v[2])
    }

    func cleanedThisWeek(_ now: Date = Date()) -> (count: Int, bytes: UInt64) {
        (0..<7).reduce((0, UInt64(0))) { acc, i in
            let c = cleanedOn(now.addingTimeInterval(-Double(i) * 86400))
            return (acc.0 + c.count, acc.1 + c.bytes)
        }
    }

    func autoLimit(_ c: AutoCategory) -> Double? { autoHours[c.rawValue] }
    func setAuto(_ c: AutoCategory, hours: Double?) { autoHours[c.rawValue] = hours }
    func keepRunning(_ id: String, for seconds: TimeInterval = 24 * 3600) { autoKeep[id] = Date().addingTimeInterval(seconds) }
    func isKept(_ id: String, now: Date = Date()) -> Bool { autoKeep[id].map { $0 > now } ?? false }

    var quietHours: QuietHours? { quietHoursOn ? QuietHours(startHour: quietStart, endHour: quietEnd) : nil }

    func snooze(_ id: String, until: Date) { snoozes[id] = until }
    func ignore(_ id: String, label: String) { ignored[id] = label }
    func unignore(_ id: String) { ignored[id] = nil }
    func isHidden(_ id: String, now: Date = Date()) -> Bool {
        ignored[id] != nil || (snoozes[id].map { $0 > now } ?? false)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Slop Cleaner: launch at login change failed: \(error.localizedDescription)")
            }
        }
    }
}
