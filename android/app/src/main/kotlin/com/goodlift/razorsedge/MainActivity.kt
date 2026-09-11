package com.goodlift.razorsedge

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ensureNotificationChannels()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // super registers the generated plugins; keep it first.
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "goodlift/notifications")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openSettings" -> {
                        openNotificationSettings()
                        result.success(null)
                    }
                    "clearDelivered" -> {
                        NotificationManagerCompat.from(this).cancelAll()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * The three push categories, one stable channel each (ids mirror
     * functions/push/push_model.js ANDROID_CHANNEL). Creating an existing
     * channel again is a no-op, so the importance and sound a person chose
     * in system settings are never overridden.
     */
    private fun ensureNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channels = listOf(
            NotificationChannel(
                "goodlift_friend_requests",
                "Friend requests",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply { description = "When someone sends you a friend request" },
            NotificationChannel(
                "goodlift_friend_accepted",
                "Friend request accepted",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply { description = "When someone accepts your friend request" },
            NotificationChannel(
                "goodlift_direct_messages",
                "Direct messages",
                NotificationManager.IMPORTANCE_HIGH
            ).apply { description = "When a friend sends you a message" }
        )
        manager.createNotificationChannels(channels)
    }

    private fun openNotificationSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(android.net.Uri.fromParts("package", packageName, null))
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }
}
