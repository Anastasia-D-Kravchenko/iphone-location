import Foundation
import UIKit
import UserNotifications

extension Notification.Name {
    static let holdChanged = Notification.Name("holdChanged")
}

/// What is faked right now, shared by the app screen and the notification buttons.
enum HoldStore {
    private static var defaults: UserDefaults { .standard }

    /// The hold time picked in the app; 0 = no limit.
    static var minutes: Int { defaults.object(forKey: "holdMinutes") as? Int ?? 15 }
    /// How much "Prolong" adds.
    static var prolongMinutes: Int { minutes == 0 ? 15 : minutes }

    static var devices: [String] {
        get { defaults.stringArray(forKey: "holdDevices") ?? [] }
        set { defaults.set(newValue, forKey: "holdDevices") }
    }

    static var api: API {
        API(host: defaults.string(forKey: "host") ?? Config.host,
            token: defaults.string(forKey: "token") ?? Config.token)
    }
}

func holdLabel(_ minutes: Int) -> String {
    if minutes == 0 { return "No limit" }
    return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h"
}

/// Local notifications: a warning before the real location comes back (with Prolong / Stop), and one when it does.
enum Reminder {
    static let category = "HOLD"
    private static let ids = ["hold-reminder", "hold-ended"]
    private static var center: UNUserNotificationCenter { .current() }

    static func setup() {
        registerButtons()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func registerButtons() {
        let prolong = UNNotificationAction(identifier: "PROLONG",
                                           title: "Keep fake location +\(holdLabel(HoldStore.prolongMinutes))")
        let stop = UNNotificationAction(identifier: "STOP", title: "Show real location now", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [prolong, stop], intentIdentifiers: []),
        ])
    }

    static func schedule(until: Date?) {
        cancel()
        guard let until else { return }
        let left = until.timeIntervalSinceNow
        guard left > 3 else { return }
        let lead = left > 120 ? 60 : left / 2

        let warn = UNMutableNotificationContent()
        warn.title = "Real location soon"
        warn.body = (lead >= 60 ? "In 1 minute" : "In \(Int(lead)) seconds")
            + " your devices show where you really are. Hold this notification to keep the fake location or stop now."
        warn.sound = .default
        warn.categoryIdentifier = category
        add("hold-reminder", warn, after: left - lead)

        let end = UNMutableNotificationContent()
        end.title = "Real location is back"
        end.body = "Your devices show where you really are again."
        end.sound = .default
        add("hold-ended", end, after: left + 5)
    }

    static func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private static func add(_ id: String, _ content: UNNotificationContent, after seconds: TimeInterval) {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Reminder.setup()
        ExpiryReminder.schedule()
        return true
    }

    // Show the banner even while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let api = HoldStore.api
        switch response.actionIdentifier {
        case "PROLONG":
            var until: Date?
            for id in HoldStore.devices {
                if let u = try? await api.extend(id, minutes: HoldStore.prolongMinutes) { until = until.map { min($0, u) } ?? u }
            }
            for s in await DirectSession.all {
                await s.extend(minutes: HoldStore.prolongMinutes)
                if let u = await s.until { until = until.map { min($0, u) } ?? u }
            }
            Reminder.schedule(until: until)
        case "STOP":
            for id in HoldStore.devices { try? await api.reset(id) }
            for s in await DirectSession.all where await s.isActive { try? await s.stop() }
            Reminder.cancel()
        default:
            break
        }
        await MainActor.run { NotificationCenter.default.post(name: .holdChanged, object: nil) }
    }
}

/// One day before the free 7-day signing runs out, remind to be on home Wi-Fi (the Mac renews
/// by itself every 6 h) or to plug the iPhone in.
enum ExpiryReminder {
    static var expiry: Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>"),
              let plist = try? PropertyListSerialization.propertyList(
                  from: Data(text[start.lowerBound..<end.upperBound].utf8), format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    static func schedule() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["app-expiry"])
        guard let expiry, case let fire = expiry.addingTimeInterval(-24 * 3600), fire > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Location app needs renewing"
        content.body = "It stops opening \(expiry.formatted(date: .abbreviated, time: .shortened)). "
            + "Be on home Wi‑Fi with the Mac on (it renews by itself), or plug the iPhone into the Mac."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
        center.add(UNNotificationRequest(identifier: "app-expiry", content: content, trigger: trigger))
    }
}
