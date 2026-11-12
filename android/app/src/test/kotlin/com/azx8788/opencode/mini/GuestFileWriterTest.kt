package com.azx8788.opencode.mini

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions

/**
 * The refusals that matter for a file the app writes inside a guest folder.
 *
 * Every case here is one the old shell path could not express: a segment that
 * climbs (`..`), an absolute path, a link planted as the file or as a folder
 * above it, and a folder swapped for a link between the check and the write.
 * The write itself is pinned to the same properties `ServerPasswordWriter`
 * has: owner-only mode, a full read-back, and a previous file left intact when
 * the write fails.
 */
class GuestFileWriterTest {
    private fun temp(): File = Files.createTempDirectory("oc-guest-").toFile()

    private fun profile(root: File): File =
        File(root, "profiles/alice").also { it.mkdirs() }

    @Test
    fun `writes a file below the profile and reads it back`() {
        val root = temp()
        val base = profile(root)
        val written = GuestFileWriter.write(base, "claude/settings.json", "{\"a\":1}".toByteArray())
        assertTrue(written)
        assertEquals("{\"a\":1}", File(base, "claude/settings.json").readText())
        assertFalse(File(base, "claude/settings.json.tmp").exists())
    }

    @Test
    fun `the mode is owner only`() {
        val root = temp()
        val base = profile(root)
        GuestFileWriter.write(base, "claude/settings.json", "x".toByteArray())
        val mode = Files.getPosixFilePermissions(File(base, "claude/settings.json").toPath())
        assertEquals(PosixFilePermissions.fromString("rw-------"), mode)
    }

    @Test
    fun `a parent folder is created with the file's own mode`() {
        val root = temp()
        val base = profile(root)
        GuestFileWriter.write(base, "a/b/c.json", "x".toByteArray())
        assertTrue(File(base, "a/b/c.json").isFile)
    }

    @Test
    fun `a climbing segment is refused and writes nothing`() {
        val root = temp()
        val base = profile(root)
        val outside = File(root, "outside.json")
        for (path in listOf("../outside.json", "claude/../../outside.json", "./x.json")) {
            try {
                GuestFileWriter.write(base, path, "x".toByteArray())
                fail("accepted $path")
            } catch (_: GuestFileWriter.Refused) {
                // expected
            }
        }
        assertFalse(outside.exists())
    }

    @Test
    fun `an absolute path is refused`() {
        val root = temp()
        val base = profile(root)
        try {
            GuestFileWriter.write(base, "/etc/passwd", "x".toByteArray())
            fail("accepted an absolute path")
        } catch (_: GuestFileWriter.Refused) {
            // expected
        }
    }

    @Test
    fun `a control character in a segment is refused`() {
        val root = temp()
        val base = profile(root)
        for (path in listOf("a\u0000b.json", "a b.json", "claude/settings.json\n")) {
            try {
                GuestFileWriter.write(base, path, "x".toByteArray())
                fail("accepted $path")
            } catch (_: GuestFileWriter.Refused) {
                // expected
            }
        }
    }

    @Test
    fun `a symlinked file is refused and the link target is untouched`() {
        val root = temp()
        val base = profile(root)
        File(base, "claude").mkdirs()
        val target = File(root, "elsewhere.json").also { it.writeText("{}") }
        Files.createSymbolicLink(File(base, "claude/settings.json").toPath(), target.toPath())
        try {
            GuestFileWriter.write(base, "claude/settings.json", "{\"a\":1}".toByteArray())
            fail("wrote through a link")
        } catch (_: GuestFileWriter.Refused) {
            // expected
        }
        assertEquals("{}", target.readText())
        assertTrue(Files.isSymbolicLink(File(base, "claude/settings.json").toPath()))
    }

    @Test
    fun `a symlinked folder is refused`() {
        val root = temp()
        val base = profile(root)
        val outside = File(root, "outside").also { it.mkdirs() }
        Files.createSymbolicLink(File(base, "claude").toPath(), outside.toPath())
        try {
            GuestFileWriter.write(base, "claude/settings.json", "x".toByteArray())
            fail("wrote through a linked folder")
        } catch (_: GuestFileWriter.Refused) {
            // expected
        }
        assertFalse(File(outside, "settings.json").exists())
    }

    @Test
    fun `a folder where the file belongs is refused and left as a folder`() {
        val root = temp()
        val base = profile(root)
        File(base, "claude").mkdirs()
        val file = File(base, "claude/settings.json").also { it.writeText("old") }
        // A folder where the file should be: the rename cannot land.
        file.delete()
        file.mkdirs()
        try {
            GuestFileWriter.write(base, "claude/settings.json", "new".toByteArray())
            fail("wrote over a folder")
        } catch (_: GuestFileWriter.Refused) {
            // expected: refused before any write
        }
        assertTrue(file.isDirectory)
        // Nothing was left behind beside it.
        assertEquals(
            listOf("settings.json"),
            File(base, "claude").list()!!.sorted(),
        )
    }

    @Test
    fun `an empty profile id is refused`() {
        val root = temp()
        for (id in listOf("", "..", "a/b", "a b", "x".repeat(81))) {
            try {
                GuestFileWriter.profileRoot(File(root, "profiles"), id)
                fail("accepted profile $id")
            } catch (_: GuestFileWriter.Refused) {
                // expected
            }
        }
    }

    @Test
    fun `a dotfile name is still a name`() {
        val root = temp()
        val base = profile(root)
        GuestFileWriter.write(base, "claude/.claude.json", "{}".toByteArray())
        assertEquals("{}", File(base, "claude/.claude.json").readText())
    }

    @Test
    fun `a receipt is read once and removed`() {
        val root = temp()
        val share = File(root, "share").also { it.mkdirs() }
        val receipt = File(share, "oc-agent-removal-${"a".repeat(32)}")
        receipt.writeText("12 0")
        Files.setPosixFilePermissions(receipt.toPath(), PosixFilePermissions.fromString("rw-------"))
        val bytes = GuestFileWriter.readAndRemove(share, receipt.name, 96)
        assertArrayEquals("12 0".toByteArray(), bytes)
        assertFalse(receipt.exists())
    }

    @Test
    fun `a receipt with the wrong mode is refused and left in place`() {
        val root = temp()
        val share = File(root, "share").also { it.mkdirs() }
        val receipt = File(share, "oc-agent-removal-${"b".repeat(32)}")
        receipt.writeText("12 0")
        Files.setPosixFilePermissions(receipt.toPath(), PosixFilePermissions.fromString("rw-r--r--"))
        try {
            GuestFileWriter.readAndRemove(share, receipt.name, 96)
            fail("read a world-readable receipt")
        } catch (_: GuestFileWriter.Refused) {
            // expected
        }
        assertTrue(receipt.exists())
    }

    @Test
    fun `a receipt over the size bound is refused`() {
        val root = temp()
        val share = File(root, "share").also { it.mkdirs() }
        val receipt = File(share, "oc-agent-removal-${"c".repeat(32)}")
        receipt.writeText("x".repeat(97))
        Files.setPosixFilePermissions(receipt.toPath(), PosixFilePermissions.fromString("rw-------"))
        try {
            GuestFileWriter.readAndRemove(share, receipt.name, 96)
            fail("read an oversized receipt")
        } catch (_: GuestFileWriter.Refused) {
            // expected
        }
        assertTrue(receipt.exists())
    }

    @Test
    fun `a receipt behind a link is refused`() {
        val root = temp()
        val share = File(root, "share").also { it.mkdirs() }
        val target = File(root, "elsewhere").also { it.writeText("12 0") }
        Files.setPosixFilePermissions(target.toPath(), PosixFilePermissions.fromString("rw-------"))
        val link = File(share, "oc-agent-removal-${"d".repeat(32)}")
        Files.createSymbolicLink(link.toPath(), target.toPath())
        try {
            GuestFileWriter.readAndRemove(share, link.name, 96)
            fail("read through a link")
        } catch (_: GuestFileWriter.Refused) {
            // expected
        }
        assertTrue(target.exists())
    }
}
