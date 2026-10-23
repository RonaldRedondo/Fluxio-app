import AppKit
import UserNotifications

/// Notificaciones del sistema con el botón "Mostrar en Finder".
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private let categoryID = "CONVERSO_RESULT"
    private let showActionID = "SHOW_IN_FINDER"
    private let center = UNUserNotificationCenter.current()

    func setUp() {
        center.delegate = self
        let show = UNNotificationAction(identifier: showActionID, title: "Mostrar en Finder", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: categoryID, actions: [show], intentIdentifiers: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(title: String, body: String, files: [URL]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = categoryID
        content.userInfo = ["paths": files.map(\.path)]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Mostrar la notificación aunque Fluxio esté en primer plano.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    // Clic en la notificación o en "Mostrar en Finder".
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let paths = response.notification.request.content.userInfo["paths"] as? [String] ?? []
        let urls = paths.map { URL(fileURLWithPath: $0) }
        DispatchQueue.main.async {
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
        completionHandler()
    }
}
