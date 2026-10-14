import UserNotifications
import WebKit

/// Faith Map local-notifications bridge.
///
/// Web Push does not exist inside a WKWebView, so reminders that the
/// web app normally delivers by push are scheduled on-device instead.
/// The web app calls:
///   window.webkit.messageHandlers.notifications.postMessage({action: ...})
/// Actions:
///   requestAuthorization — ask the user for notification permission
///   getAuthorizationStatus — report the current permission state
///   schedule — {id, title, body, timestamp(ms)} for a one-shot, or
///              {id, title, body, repeatDaily: true, hour, minute}
///   cancel — {id}
///   cancelPrefix — {prefix} (used to roll the fasting/verse windows)
///   cancelAll
/// Replies are dispatched to the page as
///   CustomEvent('faithmap-notifications', {detail: {...}})
/// mirroring the StoreKit bridge's 'faithmap-storekit' events.
class NotificationManager: NSObject {
    static let shared = NotificationManager()

    private weak var webView: WKWebView?
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    // MARK: - JS message handling

    func handleJSMessage(_ body: [String: Any]) {
        guard let action = body["action"] as? String else { return }
        switch action {
        case "requestAuthorization":
            center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, _ in
                self?.reportStatus()
            }
        case "getAuthorizationStatus":
            reportStatus()
        case "schedule":
            schedule(body)
        case "cancel":
            if let id = body["id"] as? String {
                center.removePendingNotificationRequests(withIdentifiers: [id])
                notify(["type": "cancelled", "id": id])
            }
        case "cancelPrefix":
            if let prefix = body["prefix"] as? String {
                center.getPendingNotificationRequests { [weak self] requests in
                    let ids = requests.map { $0.identifier }.filter { $0.hasPrefix(prefix) }
                    if !ids.isEmpty {
                        self?.center.removePendingNotificationRequests(withIdentifiers: ids)
                    }
                    self?.notify(["type": "cancelledPrefix", "prefix": prefix, "count": ids.count])
                }
            }
        case "cancelAll":
            center.removeAllPendingNotificationRequests()
            notify(["type": "cancelledAll"])
        default:
            break
        }
    }

    // MARK: - Scheduling

    private func schedule(_ body: [String: Any]) {
        guard let id = body["id"] as? String,
              let title = body["title"] as? String,
              let text = body["body"] as? String else {
            notify(["type": "error", "message": "schedule needs id, title and body"])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = text
        content.sound = .default

        let trigger: UNNotificationTrigger
        if (body["repeatDaily"] as? Bool) == true {
            let hour = (body["hour"] as? NSNumber)?.intValue ?? 8
            let minute = (body["minute"] as? NSNumber)?.intValue ?? 0
            var comps = DateComponents()
            comps.hour = hour
            comps.minute = minute
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        } else if let ts = (body["timestamp"] as? NSNumber)?.doubleValue {
            let date = Date(timeIntervalSince1970: ts / 1000.0)
            if date <= Date() {
                // A calendar trigger in the past would never fire; skip it
                // quietly — the web app only schedules future reminders and
                // rolls the window forward on each open.
                notify(["type": "scheduleSkipped", "id": id])
                return
            }
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        } else {
            notify(["type": "error", "message": "schedule needs timestamp or repeatDaily"])
            return
        }

        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request) { [weak self] error in
            if let error = error {
                self?.notify(["type": "error", "message": error.localizedDescription])
            } else {
                self?.notify(["type": "scheduled", "id": id])
            }
        }
    }

    // MARK: - Authorization status

    private func reportStatus() {
        center.getNotificationSettings { [weak self] settings in
            let status: String
            switch settings.authorizationStatus {
            case .authorized: status = "authorized"
            case .denied: status = "denied"
            case .notDetermined: status = "notDetermined"
            case .provisional: status = "provisional"
            case .ephemeral: status = "ephemeral"
            @unknown default: status = "unknown"
            }
            self?.notify(["type": "authorization", "status": status])
        }
    }

    // MARK: - Web reply

    /// Send an event back to the web app. The detail payload is encoded
    /// as JSON so arbitrary notification text can never break the JS.
    private func notify(_ detail: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: detail),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.dispatchEvent(new CustomEvent('faithmap-notifications', {detail: \(json)}))"
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
