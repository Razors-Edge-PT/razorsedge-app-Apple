import Flutter
import UIKit
import FBSDKCoreKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    ApplicationDelegate.shared.application(
      application,
      didFinishLaunchingWithOptions: launchOptions
    )
    GeneratedPluginRegistrant.register(with: self)
    registerNotificationChannel()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // "goodlift/notifications" — see lib/push/notification_platform.dart.
  // Push registration, APNs token forwarding and taps are handled by the
  // firebase_messaging plugin through FlutterAppDelegate; this channel only
  // opens the app's settings and clears delivered notifications at logout.
  private func registerNotificationChannel() {
    guard let registrar = self.registrar(forPlugin: "GoodLiftNotifications") else { return }
    let channel = FlutterMethodChannel(
      name: "goodlift/notifications",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "openSettings":
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        result(nil)
      case "clearDelivered":
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        result(nil)
      case "clearNotifications":
        // Targeted removal: only delivered alerts whose identifier matches a
        // tag/prefix the app asked for, or whose payload names one of the
        // conversations (which covers alerts sent before the identifier
        // carried the conversation). The identifier of a remote notification
        // is its apns-collapse-id, which the server sets to the same tag
        // Android uses.
        let args = call.arguments as? [String: Any] ?? [:]
        let prefixes = args["tagPrefixes"] as? [String] ?? []
        let tags = args["tags"] as? [String] ?? []
        let convIds = args["convIds"] as? [String] ?? []
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
          let ids: [String] = delivered.compactMap { note in
            let identifier = note.request.identifier
            if tags.contains(identifier) { return identifier }
            if prefixes.contains(where: { !$0.isEmpty && identifier.hasPrefix($0) }) { return identifier }
            if let conv = note.request.content.userInfo["convId"] as? String,
               convIds.contains(conv) {
              return identifier
            }
            return nil
          }
          if !ids.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: ids)
          }
          DispatchQueue.main.async { result(ids.count) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
