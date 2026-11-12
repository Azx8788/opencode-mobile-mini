package com.azx8788.opencode.mini

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.PosixFilePermissions
import java.util.UUID

/**
 * Writes one small secret file atomically, with no guest process.
 *
 * Kept free of Android types so its failure modes are testable on a plain JVM
 * (see `ServerPasswordWriterTest`): a target that is a link, a write that must
 * not replace it, and a failure that must leave the old file exactly as it
 * was. The AI-team start used to reach this file through a proot shell, which
 * queued behind the installer lock and failed as an unclassified
 * `builtin_linux` error.
 */
object ServerPasswordWriter {
    /** Owner read/write only. Applied before the rename, never after. */
    const val MODE = "rw-------"

    /**
     * Writes [bytes] to [target] through a unique temp file in the same
     * directory, then renames it over [target] in one step.
     *
     * Returns true only when the bytes read back equal [bytes]. A false return
     * still means the rename happened: it says another writer replaced the
     * content between the rename and the read, which is exactly the case a
     * length check would miss. [readBack] exists for that test.
     *
     * On an exception the target is untouched: the temp file is removed and
     * nothing is renamed.
     */
    @Throws(IOException::class)
    fun write(
        target: File,
        bytes: ByteArray,
        readBack: ((File) -> ByteArray)? = null,
    ): Boolean {
        val directory = target.parentFile ?: throw IOException("no parent directory")
        if (!directory.isDirectory && !directory.mkdirs() && !directory.isDirectory) {
            throw IOException("no directory")
        }
        // A link would send the secret somewhere this app does not own, and an
        // atomic move would replace the link itself: refuse either way.
        if (Files.isSymbolicLink(target.toPath())) throw IOException("target is a link")
        // Unique per writer: two starts must never share one temp file, or one
        // writer's bytes land under the other writer's rename.
        val temp = File(directory, "${target.name}.${UUID.randomUUID()}.tmp")
        try {
            Files.newOutputStream(
                temp.toPath(),
                StandardOpenOption.CREATE_NEW,
                StandardOpenOption.WRITE,
            ).use { out ->
                out.write(bytes)
                out.flush()
            }
            // Set before the rename: the file is never readable by another app,
            // not even for the moment between write and rename.
            Files.setPosixFilePermissions(
                temp.toPath(),
                PosixFilePermissions.fromString(MODE),
            )
            Files.move(
                temp.toPath(),
                target.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
            // Content, not length: two passwords of equal length are common,
            // so a length check would bless the other writer's file.
            val actual = (readBack ?: { Files.readAllBytes(it.toPath()) })(target)
            return actual.contentEquals(bytes)
        } finally {
            // After a successful move the temp name no longer exists.
            Files.deleteIfExists(temp.toPath())
        }
    }
}
