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
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
