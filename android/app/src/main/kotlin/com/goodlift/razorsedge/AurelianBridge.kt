package com.goodlift.razorsedge

import android.app.Activity
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Android glue for the Aurelian voice bridge; the decisions are in [AurelianBridgeCore],
 * [AurelianRequestParser] and [AurelianCallerPolicy].
 *
 *     Aurelian ─explicit Intent─> MainActivity ─> verify caller ─> parse ─> queue
 *        Dart bridge scope mounted ("ready") ─> "command" over goodlift/aurelian ─> Dart bus
 *        Dart result ─> reply PendingIntent (once) ─> Aurelian
 *
 * Its own channel, "goodlift/aurelian": nothing here touches notification routing. Requests from
 * anyone but Aurelian are dropped without a reply. Nothing is logged but command names and statuses.
 */
class AurelianBridge(private val activity: Activity, messenger: BinaryMessenger) {

    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())
    private val core = AurelianBridgeCore(
        deliver = { request, onResult ->
            channel.invokeMethod(
                "command",
                request.toChannelMap(),
                object : MethodChannel.Result {
                    @Suppress("UNCHECKED_CAST")
                    override fun success(result: Any?) = onResult(result as? Map<String, Any?>)
                    override fun error(code: String, message: String?, details: Any?) =
                        onResult(AurelianBridgeCore.status("failed", "GoodLift could not do that"))
                    override fun notImplemented() =
                        onResult(AurelianBridgeCore.status("unavailable", "GoodLift isn't ready"))
                },
            )
        },
        nowMs = SystemClock::elapsedRealtime,
    )
    private val expiry = object : Runnable {
        override fun run() {
            core.expire()
            if (core.outstanding > 0) main.postDelayed(this, EXPIRY_POLL_MS)
        }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "ready" -> {
                    core.markReady()
                    result.success(null)
                }
                "notReady" -> {
                    core.markNotReady()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** True if [intent] was a bridge request (handled or refused); the caller must not route it elsewhere. */
    fun handle(intent: Intent?): Boolean {
        if (intent?.action != AurelianBridgeProtocol.ACTION) return false
        val extras = intent.extras
        // Consume it: an activity recreation or a later getIntent() must never replay the command.
        intent.action = null
        intent.replaceExtras(Bundle())
        if (extras == null) return true

        val caller = parcelable(extras, AurelianBridgeProtocol.EXTRA_CALLER)
        val reply = parcelable(extras, AurelianBridgeProtocol.EXTRA_REPLY)
        if (!callerIsAurelian(caller) || reply == null || reply.creatorPackage != AurelianBridgeProtocol.AURELIAN_PACKAGE) {
            if (AurelianCallerPolicy.ALLOWED_AURELIAN_CERT_SHA256.isEmpty()) {
                Log.w(TAG, "Bridge request dropped: this build trusts no Aurelian certificate")
            }
            Log.w(TAG, "Bridge request from an untrusted caller dropped")
            return true
        }
        val target = AurelianReplyTarget { fields -> sendReply(reply, fields) }
        when (val parsed = AurelianRequestParser.parse(rawExtras(extras), SystemClock.elapsedRealtime())) {
            is AurelianParse.Rejected -> {
                Log.i(TAG, "Bridge request refused: ${parsed.status}")
                parsed.requestId?.let { id ->
                    target.send(AurelianBridgeCore.replyFields(id, AurelianBridgeCore.status(parsed.status, parsed.message)))
                }
            }
            is AurelianParse.Accepted -> {
                Log.i(TAG, "Bridge command ${parsed.request.command}")
                core.submit(parsed.request, target)
                main.removeCallbacks(expiry)
                main.postDelayed(expiry, EXPIRY_POLL_MS)
            }
        }
        return true
    }

    private fun callerIsAurelian(caller: PendingIntent?): Boolean {
        if (caller == null) return false
        // Signing-certificate checks need Android 9; older devices simply cannot use the bridge.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        val pm = activity.packageManager
        val uidPackages = pm.getPackagesForUid(caller.creatorUid)?.toList().orEmpty()
        val signed = AurelianCallerPolicy.ALLOWED_AURELIAN_CERT_SHA256.any { hex ->
            try {
                pm.hasSigningCertificate(
                    AurelianBridgeProtocol.AURELIAN_PACKAGE,
                    AurelianCallerPolicy.hexToBytes(hex),
                    PackageManager.CERT_INPUT_SHA256,
                )
            } catch (e: RuntimeException) {
                false
            }
        }
        return AurelianCallerPolicy.isTrusted(caller.creatorPackage, uidPackages, signed)
    }

    private fun sendReply(reply: PendingIntent, fields: Map<String, Any>): Boolean {
        val fill = Intent()
        for ((key, value) in fields) {
            when (value) {
                is String -> fill.putExtra(key, value)
                is ArrayList<*> -> fill.putStringArrayListExtra(key, ArrayList(value.filterIsInstance<String>()))
            }
        }
        return try {
            reply.send(activity, 0, fill)
            true
        } catch (e: PendingIntent.CanceledException) {
            false
        }
    }

    /** Only the protocol's own keys, with their raw values. */
    private fun rawExtras(extras: Bundle): Map<String, Any?> {
        val out = HashMap<String, Any?>()
        for (key in extras.keySet()) {
            if (key == AurelianBridgeProtocol.EXTRA_CALLER || key == AurelianBridgeProtocol.EXTRA_REPLY) continue
            if (!key.startsWith("aurelian.")) continue
            @Suppress("DEPRECATION")
            out[key] = extras.get(key)
        }
        return out
    }

    private fun parcelable(extras: Bundle, key: String): PendingIntent? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            extras.getParcelable(key, PendingIntent::class.java)
        } else {
            @Suppress("DEPRECATION")
            extras.getParcelable(key) as? PendingIntent
        }

    private companion object {
        const val TAG = "GoodLiftAurelian"
        const val CHANNEL = "goodlift/aurelian"
        const val EXPIRY_POLL_MS = 1_000L
    }
}
