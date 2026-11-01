import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == BackgroundDownloadManager.sessionIdentifier {
            BackgroundDownloadManager.shared.backgroundCompletionHandler = completionHandler
        } else {
            DownloadCenter.shared.backgroundCompletionHandler = completionHandler
        }
    }
}

@main
struct ClipHarborApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        BackgroundDownloadManager.shared.restoreTasks()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    var body: some Scene {
        WindowGroup {
            BrowserScreen()
        }
    }
}
