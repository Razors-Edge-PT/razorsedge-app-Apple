package com.goodlift.razorsedge

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {

    private var notificationChannel: MethodChannel? = null

    /** Extra key on the Activity intent for a tap on a notification GoodLift posted itself. */
    private val EXTRA_TAP_DATA = "goodlift_tap_data"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ensureNotificationChannels()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // super registers the generated plugins; keep it first.
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "goodlift/notifications")
        notificationChannel = channel
        channel.setMethodCallHandler { call, result ->
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
                "postNotification" -> {
                    val tag = call.argument<String>("tag")
                    val channelId = call.argument<String>("channelId")
                    val title = call.argument<String>("title") ?: ""
                    val body = call.argument<String>("body") ?: ""
                    @Suppress("UNCHECKED_CAST")
                    val data = call.argument<Map<String, String>>("data") ?: emptyMap()
                    if (tag == null || channelId == null) {
                        result.success(false)
                    } else {
                        result.success(postNotification(tag, channelId, title, body, data))
                    }
                }
                "takePendingTap" -> {
                    result.success(takePendingTap())
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * The app was launched (cold start) or brought to the foreground by tapping
     * a notification GoodLift posted itself while running — see
     * [postNotification]. FCM's own killed/background notifications are
     * handled separately, by firebase_messaging's own plugin
     * (getInitialMessage / onMessageOpenedApp); this path exists only for the
     * ones this Activity posts directly.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val data = intent.getStringExtra(EXTRA_TAP_DATA) ?: return
        intent.removeExtra(EXTRA_TAP_DATA)
        notificationChannel?.invokeMethod("notificationTapped", jsonToMap(data))
    }

    /**
     * A tap that started this process fresh: read once, then cleared, so a
     * later resume never redelivers it. Null when this launch was not one.
     */
    private fun takePendingTap(): Map<String, String>? {
        val data = intent?.getStringExtra(EXTRA_TAP_DATA) ?: return null
        intent?.removeExtra(EXTRA_TAP_DATA)
        return jsonToMap(data)
    }

    private fun jsonToMap(json: String): Map<String, String> {
        return try {
            val obj = JSONObject(json)
            val out = HashMap<String, String>()
            obj.keys().forEach { k -> out[k] = obj.optString(k, "") }
            out
        } catch (e: Exception) {
            emptyMap()
        }
    }

    /**
     * Posts a system notification while the app is running — the foreground
     * counterpart to what FCM posts itself in the background or killed. Uses
     * the SAME tag as the server would have used for this interaction, so the
     * existing cancellation (clearNotifications/deliveredTags) and the
     * launcher badge both treat it identically either way.
     *
     * The tap re-enters this Activity carrying [data] as JSON, handled above
     * by onNewIntent (already running) or takePendingTap (cold start) — the
     * same routing data a killed-state FCM tap would have carried, so
     * PushRouter cannot tell the two apart.
     */
    private fun postNotification(
        tag: String,
        channelId: String,
        title: String,
        body: String,
        data: Map<String, String>
    ): Boolean {
        val manager = getSystemService(NotificationManager::class.java) ?: return false
        return try {
            val tapIntent = Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(EXTRA_TAP_DATA, JSONObject(data as Map<*, *>).toString())
            }
            val pendingIntent = PendingIntent.getActivity(
                this,
                tag.hashCode(),
                tapIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val notification = NotificationCompat.Builder(this, channelId)
                .setSmallIcon(R.drawable.ic_stat_goodlift)
                .setColor(ContextCompat.getColor(this, R.color.notification_accent))
                .setContentTitle(title)
                .setContentText(body)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .build()
            NotificationManagerCompat.from(this).notify(tag, 0, notification)
            true
        } catch (e: SecurityException) {
            // Permission not granted; nothing to post.
            false
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
