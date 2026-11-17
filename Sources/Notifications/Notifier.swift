import Foundation
import UserNotifications

/// Mac notifications with buttons. Categories are fixed, so there's one per button label.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Response { case act, snooze, ignore, open, keep }

    private let center = UNUserNotificationCenter.current()
    var onResponse: ((_ suggestionID: String, _ response: Response) -> Void)?
    private(set) var authorized = false

    private static let categories: [String: String] = [
        "stop": "Shut down",
        "quit": "Quit",
        "copy": "Copy command",
        "open": "Open Claude",
        "show": "Show it",
    ]

    func setup() {
        center.delegate = self
        let snooze = UNNotificationAction(identifier: "SNOOZE", title: "Snooze 1 hour")
        let ignore = UNNotificationAction(identifier: "IGNORE", title: "Don't suggest again")
        var cats: Set<UNNotificationCategory> = []
        for (id, title) in Self.categories {
            let act = UNNotificationAction(identifier: "ACT", title: title, options: id == "stop" || id == "quit" ? [.destructive] : [])
            cats.insert(UNNotificationCategory(identifier: id, actions: [act, snooze, ignore], intentIdentifiers: []))
        }
        cats.insert(UNNotificationCategory(identifier: "info", actions: [snooze, ignore], intentIdentifiers: []))
        let keep = UNNotificationAction(identifier: "KEEP", title: "Keep it running")
        let now = UNNotificationAction(identifier: "ACT", title: "Close it now", options: [.destructive])
        cats.insert(UNNotificationCategory(identifier: "auto", actions: [keep, now], intentIdentifiers: []))
        cats.insert(UNNotificationCategory(identifier: "done", actions: [], intentIdentifiers: []))
        center.setNotificationCategories(cats)
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] ok, err in
            self?.authorized = ok
            if let err { NSLog("Slop Cleaner: notification permission error: \(err.localizedDescription)") }
        }
    }

    func post(_ s: Suggestion) {
        let content = UNMutableNotificationContent()
        content.title = s.title
        content.body = s.blockedNote.map { "\(s.detail) (\($0), so there's no button.)" } ?? s.detail
        content.sound = s.severity == .urgent ? .default : nil
        content.userInfo = ["id": s.id]
        content.threadIdentifier = "watcher"
        content.categoryIdentifier = category(for: s)
        center.add(UNNotificationRequest(identifier: s.id, content: content, trigger: nil))
    }

    /// Automate: "closing in 5 minutes" with Keep / Close now, and "closed it" afterwards.
    func postAuto(id: String, title: String, body: String, headsUp: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["id": id]
        content.threadIdentifier = "watcher-auto"
        content.categoryIdentifier = headsUp ? "auto" : "done"
        // Long batch ids carry every item; the request id only needs to be unique and stable.
        let requestID = id.hasPrefix("autobatch:") ? "autobatch-\(abs(id.hashValue))" : (headsUp ? id : id + ".done")
        center.add(UNNotificationRequest(identifier: requestID, content: content, trigger: nil))
    }

    func withdraw(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "Slop Cleaner is on"
        content.body = "This is what a suggestion looks like. It only speaks up when something is worth stopping."
        content.categoryIdentifier = "info"
        content.userInfo = ["id": "test"]
        center.add(UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content, trigger: nil))
    }

    private func category(for s: Suggestion) -> String {
        if s.blockedNote != nil { return "info" }
        switch s.action {
        case .stopEmulator, .shutdownSimulator: return "stop"
        case .terminate, .quitApp, .stopSession, .sweep: return "quit"
        case .copyCommand: return "copy"
        case .openClaude: return "open"
        case .showApp: return "show"
        case .none: return "info"
        }
    }

    // MARK: - Delegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["id"] as? String ?? ""
        let r: Response
        switch response.actionIdentifier {
        case "ACT": r = .act
        case "SNOOZE": r = .snooze
        case "IGNORE": r = .ignore
        case "KEEP": r = .keep
        default: r = .open
        }
        DispatchQueue.main.async { self.onResponse?(id, r) }
        completionHandler()
    }
}
