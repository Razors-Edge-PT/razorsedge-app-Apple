package com.goodlift.razorsedge

/**
 * The Aurelian voice bridge (GoodLift side), platform-free so it is unit tested on the JVM.
 * [AurelianBridge] is the thin Android shell around it (Intent, PendingIntent, MethodChannel).
 *
 * Protocol v1 — mirrored exactly in Aurelian's GoodLiftProtocol and in docs/aurelian_bridge.md:
 * an explicit Intent to MainActivity with [ACTION], a protocol version, a request id, a command
 * name from [COMMANDS], typed and bounded arguments, an immutable caller-proof PendingIntent created
 * by Aurelian, and a one-shot reply PendingIntent.
 */
object AurelianBridgeProtocol {
    const val VERSION = 1
    const val ACTION = "com.goodlift.razorsedge.action.AURELIAN_COMMAND"

    /** The only caller: Aurelian, identified by package AND signing certificate (see [AurelianCallerPolicy]). */
    const val AURELIAN_PACKAGE = "com.razorsedgesystems.aurelian"

    const val EXTRA_PROTOCOL = "aurelian.protocol"
    const val EXTRA_REQUEST_ID = "aurelian.requestId"
    const val EXTRA_COMMAND = "aurelian.command"
    const val EXTRA_SENT_AT = "aurelian.sentAtElapsed"
    const val EXTRA_CALLER = "aurelian.caller"
    const val EXTRA_REPLY = "aurelian.reply"
    const val ARG_PREFIX = "aurelian.arg."

    const val REPLY_REQUEST_ID = "aurelian.requestId"
    const val REPLY_STATUS = "aurelian.status"
    const val REPLY_MESSAGE = "aurelian.message"
    const val REPLY_CANDIDATES = "aurelian.candidates"
    const val REPLY_CONTEXT = "aurelian.context"

    /** Aurelian 2.0: the action service's result JSON for an `execute_action` request. */
    const val REPLY_RESULT = "aurelian.result"

    const val MAX_REQUEST_ID = 64
    const val MAX_NAME = 80
    const val MAX_MESSAGE = 200
    const val MAX_CANDIDATES = 8

    /** A spoken list of exercise names ("add bench press, rows and back squats"). */
    const val MAX_PHRASE = 200

    /** Labels picked in answer to earlier "which one?" questions for the same command. */
    const val MAX_CHOICES = 8

    /**
     * Aurelian 2.0 action envelope (JSON text) and its result. Checked here for size and shape only;
     * the Dart action service (lib/aurelian/actions/action_envelope.dart) is the one strict schema.
     */
    const val MAX_ENVELOPE = 4096
    const val MAX_RESULT = 4096

    /** A request older than this (by the system-wide elapsed clock) is stale and never executed. */
    const val MAX_AGE_MS = 15_000L

    /**
     * Unanswered requests are refused this long after Aurelian SENT them (the system-wide elapsed
     * clock both apps share), so a slow cold start cannot push GoodLift's answer past Aurelian's own
     * 15 s wait: Aurelian always gets a reply, never silence.
     */
    const val ANSWER_TIMEOUT_MS = 12_000L

    /** At most this many requests wait for the Dart side (cold start, sign-in). */
    const val MAX_QUEUED = 4

    /** The closed command set, and the arguments each may carry with their types. */
    val COMMANDS: Map<String, Map<String, ArgType>> = mapOf(
        "open_workout" to emptyMap(),
        "open_analytics" to emptyMap(),
        "add_exercise" to emptyMap(),
        "next_exercise" to emptyMap(),
        "previous_exercise" to emptyMap(),
        "add_set" to emptyMap(),
        "mark_exercise_done" to named(),
        "open_exercise_note" to emptyMap(),
        "open_set_note" to mapOf("setNumber" to ArgType.INT),
        "analytics_metric" to mapOf("metric" to ArgType.STRING),
        "select_exercise" to mapOf("name" to ArgType.STRING, "choice" to ArgType.STRING),
        "set_fields" to mapOf(
            "setNumber" to ArgType.INT,
            "weight" to ArgType.DOUBLE,
            "weightUnit" to ArgType.STRING,
            "reps" to ArgType.INT,
            "rir" to ArgType.DOUBLE,
            "velocity" to ArgType.DOUBLE,
        ) + named(),

        // GoodLift voice UX expansion (still v1: new commands and optional arguments only). Every
        // one of these goes through the same Dart handlers the screens' own buttons use.
        "navigate" to mapOf("destination" to ArgType.STRING),
        "workout_action" to mapOf("action" to ArgType.STRING),
        "add_exercises" to mapOf("phrase" to ArgType.TEXT, "choices" to ArgType.STRING_LIST),
        "clear_set" to mapOf("setNumber" to ArgType.INT) + named(),
        "remove_set" to mapOf("setNumber" to ArgType.INT) + named(),
        "delete_exercise" to named(),
        "replace_exercise" to mapOf("replacement" to ArgType.STRING) + named(),
        "add_exercise_to_circuit" to mapOf("circuit" to ArgType.INT),
        "move_to_circuit" to mapOf("circuit" to ArgType.INT) + named(),

        // Aurelian 2.0: one versioned action envelope for the Dart action service, which validates
        // it strictly, checks the signed-in account and coach access, and answers in `result`.
        "execute_action" to mapOf("envelope" to ArgType.JSON_OBJECT),
    )

    /** The optional exercise a command names, and the answers to GoodLift's "which one?" questions. */
    private fun named(): Map<String, ArgType> = mapOf("exercise" to ArgType.STRING, "choices" to ArgType.STRING_LIST)

    /**
     * STRING: a name, at most [MAX_NAME] chars. TEXT: a spoken list, at most [MAX_PHRASE] chars.
     * STRING_LIST: at most [MAX_CHOICES] names of at most [MAX_NAME] chars each.
     * JSON_OBJECT: the text of one JSON object, at most [MAX_ENVELOPE] chars, no control characters
     * outside JSON whitespace.
     */
    enum class ArgType { INT, DOUBLE, STRING, TEXT, STRING_LIST, JSON_OBJECT }
}

/** One accepted request, ready for the Dart command bus. [sentAtMs] is Aurelian's send time (elapsed clock). */
data class AurelianRequest(val requestId: String, val command: String, val args: Map<String, Any>, val sentAtMs: Long = 0) {
    /** What the Dart side receives over the goodlift/aurelian channel. */
    fun toChannelMap(): Map<String, Any> = mapOf(
        "protocol" to AurelianBridgeProtocol.VERSION,
        "requestId" to requestId,
        "command" to command,
        "args" to args,
    )
}

sealed interface AurelianParse {
    data class Accepted(val request: AurelianRequest) : AurelianParse

    /** Refused; [requestId] is known when the reply can still say which request it was. */
    data class Rejected(val requestId: String?, val status: String, val message: String) : AurelianParse
}

/**
 * Validates the extras of a bridge Intent (already verified to come from Aurelian). Pure: [extras]
 * holds only the raw values read from the Intent. Unknown protocol versions, unknown commands,
 * unknown or mistyped arguments, oversized strings and stale requests are refused.
 */
object AurelianRequestParser {
    private val REQUEST_ID = Regex("^[A-Za-z0-9-]{1,${AurelianBridgeProtocol.MAX_REQUEST_ID}}$")

    fun parse(extras: Map<String, Any?>, nowElapsedMs: Long): AurelianParse {
        val id = (extras[AurelianBridgeProtocol.EXTRA_REQUEST_ID] as? String)?.takeIf { REQUEST_ID.matches(it) }
            ?: return AurelianParse.Rejected(null, "invalid", "Missing or malformed request id")
        val version = extras[AurelianBridgeProtocol.EXTRA_PROTOCOL] as? Int
        if (version != AurelianBridgeProtocol.VERSION) {
            return AurelianParse.Rejected(id, "unsupported", "Unsupported bridge protocol version ${version ?: "?"}")
        }
        val sentAt = extras[AurelianBridgeProtocol.EXTRA_SENT_AT] as? Long
        if (sentAt == null || nowElapsedMs - sentAt > AurelianBridgeProtocol.MAX_AGE_MS || sentAt - nowElapsedMs > 1_000) {
            return AurelianParse.Rejected(id, "invalid", "Stale request")
        }
        val command = extras[AurelianBridgeProtocol.EXTRA_COMMAND] as? String
        val schema = AurelianBridgeProtocol.COMMANDS[command]
            ?: return AurelianParse.Rejected(id, "unsupported", "Unknown command")
        val args = LinkedHashMap<String, Any>()
        for ((key, value) in extras) {
            if (!key.startsWith(AurelianBridgeProtocol.ARG_PREFIX)) continue
            val name = key.removePrefix(AurelianBridgeProtocol.ARG_PREFIX)
            val type = schema[name] ?: return AurelianParse.Rejected(id, "invalid", "Unexpected argument \"$name\"")
            val ok = when (type) {
                AurelianBridgeProtocol.ArgType.INT -> value is Int
                AurelianBridgeProtocol.ArgType.DOUBLE -> value is Double && value.isFinite()
                AurelianBridgeProtocol.ArgType.STRING -> value is String && value.length <= AurelianBridgeProtocol.MAX_NAME
                AurelianBridgeProtocol.ArgType.TEXT -> value is String && value.length <= AurelianBridgeProtocol.MAX_PHRASE
                AurelianBridgeProtocol.ArgType.STRING_LIST -> value is List<*> &&
                    value.size <= AurelianBridgeProtocol.MAX_CHOICES &&
                    value.all { it is String && it.length <= AurelianBridgeProtocol.MAX_NAME }
                AurelianBridgeProtocol.ArgType.JSON_OBJECT -> value is String && isJsonObjectText(value)
            }
            if (!ok) return AurelianParse.Rejected(id, "invalid", "Bad argument \"$name\"")
            // A list crosses to Dart as a plain List<String>, never the Bundle's own ArrayList subtype.
            args[name] = if (value is List<*>) value.map { it as String } else value!!
        }
        return AurelianParse.Accepted(AurelianRequest(id, command!!, args, sentAt))
    }

    /** Size and outer shape of one JSON object; the content is validated by the Dart schema. */
    fun isJsonObjectText(text: String): Boolean {
        if (text.isEmpty() || text.length > AurelianBridgeProtocol.MAX_ENVELOPE) return false
        val trimmed = text.trim()
        if (!trimmed.startsWith("{") || !trimmed.endsWith("}")) return false
        return text.none { it < ' ' && it != '\n' && it != '\r' && it != '\t' }
    }
}

/**
 * Who may call the bridge: the PendingIntent Aurelian sends as caller proof must have been created by
 * [AurelianBridgeProtocol.AURELIAN_PACKAGE], that package must really belong to the creator UID, and
 * it must be signed with an allowed certificate. Package names can be claimed by anyone who installs
 * first; the signing certificate cannot be forged. Certificate hashes are public, not secrets.
 */
object AurelianCallerPolicy {
    /**
     * SHA-256 of the certificate Aurelian is signed with. Aurelian is a personal, sideloaded app
     * built and signed with the Android debug key on Richard's build machine (CN=Android Debug);
     * that is the ONLY Aurelian build it has, so it is the only allowed signer, in debug and release
     * GoodLift builds alike. If Aurelian ever gets its own release key, add that certificate's SHA-256
     * here (never a password or key material). An Aurelian built on another machine has a different
     * debug certificate and is refused.
     */
    val ALLOWED_AURELIAN_CERT_SHA256: Set<String> = setOf(
        "8e8d2fe3065691c3bbb57485fa3bc9ebde1f9052367201df7c36d9dd13bea763",
    )

    fun isTrusted(creatorPackage: String?, packagesForCreatorUid: List<String>, signedWithAllowedCert: Boolean): Boolean =
        creatorPackage == AurelianBridgeProtocol.AURELIAN_PACKAGE &&
            AurelianBridgeProtocol.AURELIAN_PACKAGE in packagesForCreatorUid &&
            signedWithAllowedCert

    /** "8E:8D:2F:…" or "8e8d2f…" → bytes, for PackageManager.hasSigningCertificate. */
    fun hexToBytes(hex: String): ByteArray {
        val clean = hex.replace(":", "").lowercase()
        require(clean.length % 2 == 0)
        return ByteArray(clean.length / 2) { clean.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }
}

/** Where a request's single reply goes (Aurelian's one-shot PendingIntent). */
fun interface AurelianReplyTarget {
    /** @return false if it could not be delivered (Aurelian gone, PendingIntent cancelled). */
    fun send(fields: Map<String, Any>): Boolean
}

/**
 * Queues requests until the Dart command bus is ready, hands them over in order, and replies exactly
 * once per request: with Dart's result, or with a refusal if the queue is full, the Dart side never
 * becomes ready (signed out, membership gate) or does not answer in time.
 *
 * Main thread only. [deliver] forwards one request to Dart and calls back with its result map.
 */
class AurelianBridgeCore(
    private val deliver: (AurelianRequest, (Map<String, Any?>?) -> Unit) -> Unit,
    private val nowMs: () -> Long,
) {
    private class Pending(val request: AurelianRequest, val reply: AurelianReplyTarget, val deadlineMs: Long) {
        var inFlight = false
        var answered = false
    }

    private val pending = ArrayList<Pending>()

    var ready = false
        private set

    val queued: Int get() = pending.count { !it.inFlight }
    val outstanding: Int get() = pending.size

    fun submit(request: AurelianRequest, reply: AurelianReplyTarget) {
        if (pending.any { it.request.requestId == request.requestId }) return // duplicate delivery
        if (pending.size >= AurelianBridgeProtocol.MAX_QUEUED) {
            answer(Pending(request, reply, nowMs()), status("unavailable", "GoodLift is busy — try again"))
            return
        }
        pending += Pending(request, reply, request.sentAtMs + AurelianBridgeProtocol.ANSWER_TIMEOUT_MS)
        drain()
    }

    /** Dart registered its bridge scope (signed in, past the membership gate). */
    fun markReady() {
        ready = true
        drain()
    }

    fun markNotReady() {
        ready = false
    }

    /** Refuses requests that waited or ran too long; call periodically while any are outstanding. */
    fun expire() {
        val now = nowMs()
        for (p in pending.toList()) {
            if (now >= p.deadlineMs) {
                val message = if (p.inFlight) "GoodLift took too long" else "GoodLift isn't ready — open it and sign in"
                answer(p, status("unavailable", message))
            }
        }
    }

    private fun drain() {
        if (!ready) return
        for (p in pending.toList()) {
            if (p.inFlight || p.answered) continue
            p.inFlight = true
            deliver(p.request) { result ->
                answer(p, result ?: status("failed", "GoodLift returned no result"))
            }
        }
    }

    private fun answer(p: Pending, result: Map<String, Any?>) {
        if (p.answered) return
        p.answered = true
        pending.remove(p)
        p.reply.send(replyFields(p.request.requestId, result))
    }

    companion object {
        private val STATUSES = setOf("ok", "ambiguous", "not_found", "not_handled", "unavailable", "unsupported", "invalid", "failed")

        fun status(status: String, message: String): Map<String, Any?> = mapOf("status" to status, "message" to message)

        /** Bounds and normalises Dart's result into the reply extras. */
        fun replyFields(requestId: String, result: Map<String, Any?>): Map<String, Any> {
            val status = (result["status"] as? String)?.takeIf { it in STATUSES } ?: "failed"
            val out = LinkedHashMap<String, Any>()
            out[AurelianBridgeProtocol.REPLY_REQUEST_ID] = requestId
            out[AurelianBridgeProtocol.REPLY_STATUS] = status
            (result["message"] as? String)?.take(AurelianBridgeProtocol.MAX_MESSAGE)?.let { out[AurelianBridgeProtocol.REPLY_MESSAGE] = it }
            (result["context"] as? String)?.take(AurelianBridgeProtocol.MAX_NAME)?.let { out[AurelianBridgeProtocol.REPLY_CONTEXT] = it }
            val candidates = (result["candidates"] as? List<*>)?.filterIsInstance<String>()
                ?.map { it.take(AurelianBridgeProtocol.MAX_NAME) }
                ?.take(AurelianBridgeProtocol.MAX_CANDIDATES)
            if (!candidates.isNullOrEmpty()) out[AurelianBridgeProtocol.REPLY_CANDIDATES] = ArrayList(candidates)
            // An oversized result is dropped, never truncated mid-JSON; Aurelian then reports a failure.
            (result["result"] as? String)?.takeIf { it.length <= AurelianBridgeProtocol.MAX_RESULT }
                ?.let { out[AurelianBridgeProtocol.REPLY_RESULT] = it }
            return out
        }
    }
}
