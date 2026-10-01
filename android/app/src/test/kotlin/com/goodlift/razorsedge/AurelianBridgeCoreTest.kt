package com.goodlift.razorsedge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Aurelian voice bridge's platform-free core: request parsing, caller policy, queue and replies. */
class AurelianBridgeCoreTest {

    private val now = 1_000_000L

    private fun extras(command: String = "open_workout", vararg args: Pair<String, Any?>): MutableMap<String, Any?> =
        mutableMapOf<String, Any?>(
            AurelianBridgeProtocol.EXTRA_PROTOCOL to 1,
            AurelianBridgeProtocol.EXTRA_REQUEST_ID to "0f8e7a1c-1234-4c1d-9e1f-abcdefabcdef",
            AurelianBridgeProtocol.EXTRA_COMMAND to command,
            AurelianBridgeProtocol.EXTRA_SENT_AT to now - 50,
        ).apply { for ((k, v) in args) put(AurelianBridgeProtocol.ARG_PREFIX + k, v) }

    private fun parse(e: Map<String, Any?>) = AurelianRequestParser.parse(e, now)

    // ------------------------------------------------------------------ parsing

    @Test fun acceptsEveryCommandWithTypedArguments() {
        val set = parse(extras("set_fields", "setNumber" to 1, "weight" to 135.0, "weightUnit" to "lb", "reps" to 5, "rir" to 2.0))
        set as AurelianParse.Accepted
        assertEquals("set_fields", set.request.command)
        assertEquals(mapOf("setNumber" to 1, "weight" to 135.0, "weightUnit" to "lb", "reps" to 5, "rir" to 2.0), set.request.args)
        for (command in AurelianBridgeProtocol.COMMANDS.keys) {
            assertTrue(command, parse(extras(command)) is AurelianParse.Accepted)
        }
        val map = set.request.toChannelMap()
        assertEquals(1, map["protocol"])
        assertEquals("set_fields", map["command"])
    }

    @Test fun acceptsTheVoiceUxCommandsWithBoundedTextAndLists() {
        val add = parse(extras("add_exercises", "phrase" to "bench press, suspended high row and back squats", "choices" to arrayListOf("Bench Press, Barbell")))
        add as AurelianParse.Accepted
        assertEquals(listOf("Bench Press, Barbell"), add.request.args["choices"])
        for ((command, args) in listOf(
            "navigate" to arrayOf<Pair<String, Any?>>("destination" to "leaderboard"),
            "workout_action" to arrayOf("action" to "load_template"),
            "clear_set" to arrayOf("setNumber" to 1, "exercise" to "bench press"),
            "remove_set" to arrayOf("setNumber" to 2),
            "delete_exercise" to arrayOf("exercise" to "bench press", "choices" to arrayListOf("Bench Press, Barbell")),
            "replace_exercise" to arrayOf("exercise" to "suspended high row", "replacement" to "kp face pull"),
            "add_exercise_to_circuit" to arrayOf("circuit" to 2),
            "move_to_circuit" to arrayOf("circuit" to 3, "exercise" to "back squat"),
            "mark_exercise_done" to arrayOf("exercise" to "back squat"),
            "set_fields" to arrayOf("setNumber" to 1, "weight" to 150.0, "reps" to 5, "rir" to 1.0, "exercise" to "bench press"),
        )) {
            assertTrue(command, parse(extras(command, *args)) is AurelianParse.Accepted)
        }
    }

    @Test fun rejectsOversizedOrMistypedVoiceUxArguments() {
        val bad = listOf(
            extras("add_exercises", "phrase" to "x".repeat(AurelianBridgeProtocol.MAX_PHRASE + 1)),
            extras("add_exercises", "phrase" to 5),
            extras("delete_exercise", "exercise" to "x".repeat(AurelianBridgeProtocol.MAX_NAME + 1)),
            extras("delete_exercise", "choices" to ArrayList(List(AurelianBridgeProtocol.MAX_CHOICES + 1) { "c$it" })),
            extras("delete_exercise", "choices" to arrayListOf("x".repeat(AurelianBridgeProtocol.MAX_NAME + 1))),
            extras("delete_exercise", "choices" to arrayListOf<Any>(1, 2)),
            extras("delete_exercise", "choices" to "Bench Press"),
            extras("replace_exercise", "replacement" to "x".repeat(AurelianBridgeProtocol.MAX_PHRASE)),
            extras("navigate", "phrase" to "leaderboard"),
            extras("clear_set", "setNumber" to 1.0),
            extras("move_to_circuit", "circuit" to "2"),
            // A phrase-length string is only allowed where the schema says TEXT.
            extras("navigate", "destination" to "x".repeat(AurelianBridgeProtocol.MAX_NAME + 1)),
        )
        for (e in bad) {
            val r = parse(e)
            assertTrue("$e → $r", r is AurelianParse.Rejected && r.status == "invalid")
        }
    }

    @Test fun rejectsWrongProtocolVersion() {
        val r = parse(extras().apply { put(AurelianBridgeProtocol.EXTRA_PROTOCOL, 2) }) as AurelianParse.Rejected
        assertEquals("unsupported", r.status)
        assertEquals("0f8e7a1c-1234-4c1d-9e1f-abcdefabcdef", r.requestId)
        assertTrue(parse(extras().apply { remove(AurelianBridgeProtocol.EXTRA_PROTOCOL) }) is AurelianParse.Rejected)
    }

    @Test fun rejectsMalformedRequests() {
        val bad = listOf(
            extras("delete_all_workouts"),
            extras().apply { remove(AurelianBridgeProtocol.EXTRA_REQUEST_ID) },
            extras().apply { put(AurelianBridgeProtocol.EXTRA_REQUEST_ID, "../../etc") },
            extras().apply { put(AurelianBridgeProtocol.EXTRA_REQUEST_ID, "x".repeat(65)) },
            extras("open_workout", "setNumber" to 1), // argument not in this command's schema
            extras("set_fields", "setNumber" to "1"),
            extras("set_fields", "weight" to Double.NaN),
            extras("set_fields", "weight" to 50), // Int where a Double is required
            extras("select_exercise", "name" to "x".repeat(81)),
            extras("select_exercise", "dartCode" to "print(1)"),
        )
        for (e in bad) assertTrue("$e", parse(e) is AurelianParse.Rejected)
    }

    @Test fun rejectsStaleAndFutureRequests() {
        assertTrue(parse(extras().apply { put(AurelianBridgeProtocol.EXTRA_SENT_AT, now - 16_000) }) is AurelianParse.Rejected)
        assertTrue(parse(extras().apply { put(AurelianBridgeProtocol.EXTRA_SENT_AT, now + 5_000) }) is AurelianParse.Rejected)
        assertTrue(parse(extras().apply { remove(AurelianBridgeProtocol.EXTRA_SENT_AT) }) is AurelianParse.Rejected)
    }

    // ------------------------------------------------------------------ caller

    @Test fun onlyAurelianSignedWithTheAllowedCertificateIsTrusted() {
        val aurelian = AurelianBridgeProtocol.AURELIAN_PACKAGE
        assertTrue(AurelianCallerPolicy.isTrusted(aurelian, listOf(aurelian), signedWithAllowedCert = true))
        assertFalse("wrong signer", AurelianCallerPolicy.isTrusted(aurelian, listOf(aurelian), signedWithAllowedCert = false))
        assertFalse("another app", AurelianCallerPolicy.isTrusted("com.evil.app", listOf("com.evil.app"), true))
        assertFalse("package not owned by the creator uid", AurelianCallerPolicy.isTrusted(aurelian, listOf("com.evil.app"), true))
        assertFalse("no proof", AurelianCallerPolicy.isTrusted(null, emptyList(), true))
    }

    @Test fun allowedCertificateIsAurelianSha256() {
        // JVM unit tests use the debug build's allowlist: the development certificate by default.
        val cert = AurelianCallerPolicy.ALLOWED_AURELIAN_CERT_SHA256.single()
        assertEquals(64, cert.length)
        assertEquals(32, AurelianCallerPolicy.hexToBytes(cert).size)
        assertEquals(0x8e.toByte(), AurelianCallerPolicy.hexToBytes("8E:8D")[0])
    }

    @Test fun callerAllowlistIsParsedStrictly() {
        val a = "8e8d2fe3065691c3bbb57485fa3bc9ebde1f9052367201df7c36d9dd13bea763"
        val b = "AB".repeat(32)
        assertEquals(emptySet<String>(), AurelianCallerPolicy.parseCertList(""))
        assertEquals(setOf(a), AurelianCallerPolicy.parseCertList(" $a "))
        assertEquals(setOf(a, "ab".repeat(32)), AurelianCallerPolicy.parseCertList("$a,${b.chunked(2).joinToString(":")}"))
        assertEquals("malformed entries never become trusted", emptySet<String>(),
            AurelianCallerPolicy.parseCertList("*,android,${a.dropLast(1)},${a}00"))
    }

    // ------------------------------------------------------------------ queue and replies

    private class Target : AurelianReplyTarget {
        val replies = mutableListOf<Map<String, Any>>()
        override fun send(fields: Map<String, Any>): Boolean {
            replies += fields
            return true
        }
    }

    private var clock = 0L
    private val delivered = mutableListOf<Pair<AurelianRequest, (Map<String, Any?>?) -> Unit>>()
    private val core = AurelianBridgeCore(deliver = { r, cb -> delivered += r to cb }, nowMs = { clock })

    private fun request(id: String, command: String = "open_workout") = AurelianRequest(id, command, emptyMap(), sentAtMs = clock)

    @Test fun coldStartCommandIsQueuedUntilDartIsReadyAndNotLost() {
        val target = Target()
        core.submit(request("a"), target)
        assertTrue("nothing reaches Dart before its bridge scope is mounted", delivered.isEmpty())
        assertEquals(1, core.queued)
        core.markReady()
        assertEquals(listOf("a"), delivered.map { it.first.requestId })
        delivered.single().second(mapOf("status" to "ok", "message" to "Workout opened"))
        assertEquals("ok", target.replies.single()[AurelianBridgeProtocol.REPLY_STATUS])
        assertEquals("a", target.replies.single()[AurelianBridgeProtocol.REPLY_REQUEST_ID])
        assertEquals(0, core.outstanding)
    }

    @Test fun warmCommandIsDeliveredImmediately() {
        core.markReady()
        val target = Target()
        core.submit(request("b", "set_fields"), target)
        assertEquals(1, delivered.size)
        assertEquals("set_fields", delivered.single().first.command)
    }

    @Test fun replyIsSentExactlyOnce() {
        core.markReady()
        val target = Target()
        core.submit(request("c"), target)
        val callback = delivered.single().second
        callback(mapOf("status" to "ok", "message" to "one"))
        callback(mapOf("status" to "ok", "message" to "two"))
        clock += 60_000
        core.expire()
        assertEquals(1, target.replies.size)
        assertEquals("one", target.replies.single()[AurelianBridgeProtocol.REPLY_MESSAGE])
        // A duplicate delivery of the same request id is ignored while it is outstanding.
        core.submit(request("d"), target)
        core.submit(request("d"), target)
        assertEquals(2, delivered.size)
    }

    @Test fun neverReadyMeansARefusalAfterTheTimeoutNotSilence() {
        val target = Target()
        core.submit(request("e"), target)
        clock += AurelianBridgeProtocol.ANSWER_TIMEOUT_MS - 1
        core.expire()
        assertTrue(target.replies.isEmpty())
        clock += 1
        core.expire()
        assertEquals("unavailable", target.replies.single()[AurelianBridgeProtocol.REPLY_STATUS])
        assertTrue("signed out / membership gate: never delivered", delivered.isEmpty())
    }

    @Test fun theDeadlineCountsFromWhenAurelianSentItNotFromASlowColdStart() {
        val target = Target()
        val sent = clock
        clock += 7_000 // GoodLift's process took 7 s to start and receive it
        core.submit(AurelianRequest("slow", "open_workout", emptyMap(), sentAtMs = sent), target)
        clock = sent + AurelianBridgeProtocol.ANSWER_TIMEOUT_MS
        core.expire()
        assertEquals("answered within Aurelian's 15 s wait", "unavailable", target.replies.single()[AurelianBridgeProtocol.REPLY_STATUS])
    }

    @Test fun queueIsBounded() {
        val targets = List(AurelianBridgeProtocol.MAX_QUEUED + 1) { Target() }
        targets.forEachIndexed { i, t -> core.submit(request("q$i"), t) }
        assertEquals(AurelianBridgeProtocol.MAX_QUEUED, core.queued)
        assertEquals("unavailable", targets.last().replies.single()[AurelianBridgeProtocol.REPLY_STATUS])
    }

    @Test fun repliesAreBoundedAndStatusesClosed() {
        val fields = AurelianBridgeCore.replyFields(
            "z",
            mapOf(
                "status" to "ambiguous",
                "message" to "m".repeat(1_000),
                "candidates" to List(20) { "c".repeat(200) },
                "context" to "picker",
            ),
        )
        assertEquals(AurelianBridgeProtocol.MAX_MESSAGE, (fields[AurelianBridgeProtocol.REPLY_MESSAGE] as String).length)
        val candidates = fields[AurelianBridgeProtocol.REPLY_CANDIDATES] as List<*>
        assertEquals(AurelianBridgeProtocol.MAX_CANDIDATES, candidates.size)
        assertTrue(candidates.all { (it as String).length <= AurelianBridgeProtocol.MAX_NAME })
        assertEquals("failed", AurelianBridgeCore.replyFields("z", mapOf("status" to "rm -rf"))[AurelianBridgeProtocol.REPLY_STATUS])
    }

    // ------------------------------------------------------------------ Aurelian 2.0 actions

    @Test fun executeActionCarriesOneBoundedJsonEnvelope() {
        val envelope = """{"schemaVersion":1,"requestId":"r1","idempotencyKey":"k1234567","action":"set.update","payload":{"set":1,"reps":5}}"""
        val ok = parse(extras("execute_action", "envelope" to envelope))
        ok as AurelianParse.Accepted
        assertEquals(envelope, ok.request.args["envelope"])
        for (bad in listOf(
            "[1,2]",
            "not json",
            "{" + "x".repeat(AurelianBridgeProtocol.MAX_ENVELOPE) + "}",
            "{\"a\":\"\u0000\"}",
        )) {
            assertTrue(bad.take(20), parse(extras("execute_action", "envelope" to bad)) is AurelianParse.Rejected)
        }
        assertTrue(parse(extras("execute_action", "envelope" to 42)) is AurelianParse.Rejected)
        assertTrue(parse(extras("execute_action", "envelope" to envelope, "exercise" to "bench")) is AurelianParse.Rejected)
    }

    @Test fun actionResultsPassThroughBoundedOrNotAtAll() {
        val result = """{"status":"success","summary":"ok"}"""
        val fields = AurelianBridgeCore.replyFields("r", mapOf("status" to "ok", "message" to "Action handled", "result" to result))
        assertEquals(result, fields[AurelianBridgeProtocol.REPLY_RESULT])
        val big = AurelianBridgeCore.replyFields("r", mapOf("status" to "ok", "result" to "{" + "x".repeat(AurelianBridgeProtocol.MAX_RESULT) + "}"))
        assertFalse(big.containsKey(AurelianBridgeProtocol.REPLY_RESULT))
    }
}
