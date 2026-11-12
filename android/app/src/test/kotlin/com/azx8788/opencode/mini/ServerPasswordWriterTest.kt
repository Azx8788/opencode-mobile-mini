package com.azx8788.opencode.mini

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import java.util.concurrent.Callable
import java.util.concurrent.Executors

/**
 * The four failures that matter for a credential file, on a plain JVM: the
 * write lands, a link is refused, a read-back that disagrees is reported, and
 * a failed write leaves the previous file exactly as it was. The atomic rename
 * is the property worth pinning hardest: a reader never sees half a password.
 */
class ServerPasswordWriterTest {
    private fun directory(): File = Files.createTempDirectory("password-writer").toFile()

    @Test
    fun writesTheExactBytesWithOwnerOnlyMode() {
        val target = File(directory(), "server.password")
        val bytes = "correct horse battery staple".toByteArray()

        assertTrue(ServerPasswordWriter.write(target, bytes))

        assertArrayEquals(bytes, target.readBytes())
        assertEquals(PosixFilePermissions.fromString("rw-------"),
            Files.getPosixFilePermissions(target.toPath()))
    }

    @Test
    fun createsTheParentDirectoryLikeTheOldShellDid() {
        val root = directory()
        val target = File(root, "root/.oc-builtin/server.password")

        assertTrue(ServerPasswordWriter.write(target, "pw".toByteArray()))
        assertTrue(target.isFile)
    }

    @Test
    fun refusesATargetThatIsALink() {
        val root = directory()
        val real = File(root, "elsewhere").apply { writeText("untouched") }
        val link = File(root, "server.password")
        Files.createSymbolicLink(link.toPath(), real.toPath())

        try {
            ServerPasswordWriter.write(link, "pw".toByteArray())
            fail("a link must not be followed")
        } catch (_: IOException) {
            // Expected: the secret must never land wherever the link points.
        }

        assertTrue(Files.isSymbolicLink(link.toPath()))
        assertEquals("untouched", real.readText())
    }

    @Test
    fun reportsAReadBackThatDisagrees() {
        val target = File(directory(), "server.password")
        val written = "pw-one".toByteArray()

        val ok = ServerPasswordWriter.write(target, written) { "pw-two".toByteArray() }

        // The rename did happen; the answer says another writer got there in
        // between, which a length check would have blessed.
        assertFalse(ok)
        assertArrayEquals(written, target.readBytes())
    }

    @Test
    fun leavesThePreviousTargetUntouchedWhenTheWriteFails() {
        val root = directory()
        val target = File(root, "server.password")
        assertTrue(target.mkdirs())
        File(target, "keep").writeText("still here")

        try {
            ServerPasswordWriter.write(target, "pw".toByteArray())
            fail("a directory cannot be replaced by a file")
        } catch (_: IOException) {
            // Expected.
        }

        assertTrue(target.isDirectory)
        assertEquals("still here", File(target, "keep").readText())
    }

    @Test
    fun concurrentWritersNeverLeaveMixedContent() {
        val root = directory()
        val target = File(root, "server.password")
        val one = ByteArray(64 * 1024) { 0x41 }
        val two = ByteArray(64 * 1024) { 0x42 }
        val pool = Executors.newFixedThreadPool(2)
        try {
            val tasks = listOf(one, two).map { bytes ->
                pool.submit(Callable { ServerPasswordWriter.write(target, bytes) })
            }
            tasks.forEach { it.get() }
        } finally {
            pool.shutdown()
        }

        val actual = target.readBytes()
        // Either writer's file, never a splice of both: that is what the
        // per-writer temp name and the atomic rename buy.
        assertTrue(actual.contentEquals(one) || actual.contentEquals(two))
    }
}
