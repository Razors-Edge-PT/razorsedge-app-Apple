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
                    "deliveredTags" -> {
                        result.success(deliveredTags())
                    }
                    "clearNotifications" -> {
                        val prefixes = call.argument<List<String>>("tagPrefixes") ?: emptyList()
                        val tags = call.argument<List<String>>("tags") ?: emptyList()
                        result.success(cancelMatching(prefixes, tags))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Cancels only this app's delivered notifications whose tag starts with
     * one of [prefixes] or equals one of [tags], and returns how many were
     * cancelled.
     *
     * getActiveNotifications() lists THIS app's posted notifications only, so
     * it also covers the ones the system posted from FCM while the app was not
     * running — which is the whole point, since Dart never saw those. It needs
     * no special permission and cannot see other apps' notifications.
     */
    /**
     * The tags of this app's currently delivered notifications, including the
     * ones the system posted from FCM while the app was not running.
     * getActiveNotifications() is scoped to this app and needs no permission.
     */
    private fun deliveredTags(): List<String> {
        val manager = getSystemService(NotificationManager::class.java) ?: return emptyList()
        return try {
            manager.activeNotifications.mapNotNull { it.tag }
        } catch (e: SecurityException) {
            emptyList()
        }
    }

    private fun cancelMatching(prefixes: List<String>, tags: List<String>): Int {
        val manager = getSystemService(NotificationManager::class.java) ?: return 0
        var cancelled = 0
        try {
            for (posted in manager.activeNotifications) {
                val tag = posted.tag ?: continue
                val matches = tags.contains(tag) || prefixes.any { it.isNotEmpty() && tag.startsWith(it) }
                if (matches) {
                    manager.cancel(tag, posted.id)
                    cancelled++
                }
            }
        } catch (e: SecurityException) {
            // Some OEM builds restrict the query; nothing else to do.
            return cancelled
        }
        return cancelled
    }

    /**
     * One stable channel per push category (ids mirror
     * functions/push/push_model.js ANDROID_CHANNEL). Creating an existing
     * channel again is a no-op, so the importance and sound a person chose
     * in system settings are never overridden.
     *
     * A channel MUST exist before a notification names it: Android drops a
     * message addressed to an unknown channel without showing anything, which
     * is a silent failure rather than a visible one. So every id the server can
     * send is created here, including the ones added after this app version
     * shipped its first channels.
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
            ).apply { description = "When a friend sends you a message" },
            NotificationChannel(
                "goodlift_message_reactions",
                "Message reactions",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply { description = "When someone reacts to a message you sent" },
            NotificationChannel(
                "goodlift_post_comments",
                "Comments on your posts",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply { description = "When a friend comments on something you posted" },
            NotificationChannel(
                "goodlift_post_reactions",
                "Likes and Good Lifts",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "When a friend likes your post or gives your video a Good Lift"
            }
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
