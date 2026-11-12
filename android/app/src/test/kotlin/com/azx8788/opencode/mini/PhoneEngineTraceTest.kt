package com.azx8788.opencode.mini

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the alphabet against the strings the engine actually emits. The Dart
 * side (`lib/domain/phone_engine_trace.dart`) accepts the same sample
 * unchanged, so a trace in the app log is the trace native code produced.
 */
class PhoneEngineTraceTest {
    private val fullTrace =
        "prepare@0;gate:unconfined=false,server=false,procs=0,svc=0," +
            "term=false@2;after:unconfined=false,server=false,procs=0,svc=0," +
            "term=false@3;tier=proot@3;proof:false," +
            "reason=boundary_unverified@9;spawned@210;status:boundary_false@214"

    @Test
    fun keepsACompleteGateTraceCharacterForCharacter() {
        assertEquals(fullTrace, PhoneEngineTrace.sanitize(fullTrace))
    }

    @Test
    fun keepsTheBusyAndCredentialTraces() {
        val busy = "prepare@0;gate:unconfined=true,server=false,procs=0," +
            "svc=0,term=false@4;after:unconfined=true,server=false,procs=0," +
            "svc=0,term=false@1207;fail:restart_busy"
        assertEquals(busy, PhoneEngineTrace.sanitize(busy))
        assertEquals("write@0;fail:state", PhoneEngineTrace.sanitize("write@0;fail:state"))
    }

    @Test
    fun dropsAPathOrACredentialThatATraceMustNeverCarry() {
        assertEquals("datauser0com.azx8788", PhoneEngineTrace.sanitize("/data/user/0/com.azx8788"))
        // A space or a quote is outside the alphabet too: an embedded command
        // line cannot survive as readable text.
        assertEquals("printfssha", PhoneEngineTrace.sanitize("printf %s 'sha'"))
    }

    @Test
    fun cutsAtTheLimitWithAnAsciiMarker() {
        val long = "a".repeat(PhoneEngineTrace.LIMIT + 60)
        val cut = PhoneEngineTrace.sanitize(long)
        assertEquals(PhoneEngineTrace.LIMIT, cut.length)
        assertTrue(cut.endsWith("..."))
        assertEquals("a".repeat(PhoneEngineTrace.LIMIT - 3), cut.dropLast(3))
    }

    @Test
    fun leavesATraceAtTheLimitWhole() {
        val atLimit = "a".repeat(PhoneEngineTrace.LIMIT)
        assertEquals(atLimit, PhoneEngineTrace.sanitize(atLimit))
    }
}
