package com.azx8788.opencode.mini

import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.BasicFileAttributes
import java.nio.file.attribute.PosixFilePermissions
import java.util.UUID

/**
 * Writes one file inside a guest folder the app already owns, with no guest
 * process involved.
 *
 * Every write the app used to make by running a shell in Ubuntu went through
 * [BuiltinLinux.run], which queues behind the installer lock. Saving an
 * endpoint or a provider therefore failed as an unclassified `builtin_linux`
 * error whenever another phone task was still finishing — for a write that
 * needs no guest at all.
 *
 * Kept free of Android types so its refusals are testable on a plain JVM (see
 * `GuestFileWriterTest`). The refusals are the point: a path is a set of
 * segments checked one by one, never a string handed to a shell, and no
 * existing link on the way may redirect the write outside the folder it was
 * given.
 */
object GuestFileWriter {
    /** Owner read/write only. Applied before the rename, never after. */
    const val MODE = "rw-------"

    /** A folder this writer created: owner only, like the file inside it. */
    const val FOLDER_MODE = "rwx------"

    const val MAX_SEGMENTS = 12
    const val MAX_RELATIVE_LENGTH = 512
    private const val MAX_SEGMENT_LENGTH = 200

    private val PROFILE_ID = Regex("[a-zA-Z0-9_-]{1,80}")
    private val SEGMENT = Regex("[a-zA-Z0-9._-]{1,$MAX_SEGMENT_LENGTH}")

    /** A path this writer will not touch. Carries no path: only the reason. */
    class Refused(reason: String) : IOException(reason)

    /** The profile's own folder, under a root the caller has already fixed. */
    @Throws(Refused::class)
    fun profileRoot(profilesRoot: File, profileId: String): File {
        if (!PROFILE_ID.matches(profileId)) throw Refused("profile")
        return File(profilesRoot, profileId)
    }

    /**
     * The target file, after checking every segment of [relativePath] and
     * every existing folder above it.
     *
     * A segment is `[A-Za-z0-9._-]` and is neither `.` nor `..`, so `..` can
     * never climb out and an absolute path is refused before it is joined. A
     * link is refused wherever it sits: as the file itself it would send the
     * write elsewhere, and as a folder above it, the same.
     */
    @Throws(Refused::class)
    fun target(root: File, relativePath: String): File {
        if (relativePath.isEmpty() || relativePath.length > MAX_RELATIVE_LENGTH) {
            throw Refused("length")
        }
        if (relativePath.startsWith("/") || relativePath.contains('\u0000')) {
            throw Refused("absolute")
        }
        val parts = relativePath.split('/')
        if (parts.size > MAX_SEGMENTS) throw Refused("depth")
        for (part in parts) {
            if (part == "." || part == ".." || !SEGMENT.matches(part)) {
                throw Refused("segment")
            }
        }
        var current = root.absoluteFile
        for (part in parts.dropLast(1)) {
            current = File(current, part)
            if (Files.isSymbolicLink(current.toPath())) throw Refused("folder link")
            if (current.exists() && !current.isDirectory) throw Refused("not a folder")
        }
        val file = File(current, parts.last())
        if (Files.isSymbolicLink(file.toPath())) throw Refused("file link")
        if (file.exists() && !file.isFile) throw Refused("not a file")
        return file
    }

    /**
     * Writes [bytes] to [relativePath] under [root] through a unique temp file
     * in the same folder, then renames it over the target in one step.
     *
     * Returns true only when the bytes read back equal [bytes]. A false return
     * still means the rename happened: it says another writer replaced the
     * content between the rename and the read, which is exactly the case a
     * length check would miss.
     */
    @Throws(IOException::class)
    fun write(root: File, relativePath: String, bytes: ByteArray): Boolean {
        var target = target(root, relativePath)
        val directory = target.parentFile ?: throw Refused("parent")
        if (!directory.isDirectory) {
            // One level at a time, so every folder this writer creates is
            // owner-only from the moment it exists: `mkdirs` would leave a
            // world-readable folder around a key file.
            var cursor = root.absoluteFile
            for (part in relativePath.split('/').dropLast(1)) {
                cursor = File(cursor, part)
                if (!cursor.exists()) {
                    Files.createDirectory(cursor.toPath())
                    Files.setPosixFilePermissions(
                        cursor.toPath(),
                        PosixFilePermissions.fromString(FOLDER_MODE),
                    )
                }
            }
            if (!directory.isDirectory) throw Refused("directory")
        }
        // A folder can be created where a link was planted between the check
        // above and this line. Re-checking costs one lstat per segment and
        // closes that window to the one syscall this plain Java API cannot
        // make atomic (openat with O_NOFOLLOW on every part).
        target = target(root, relativePath)
        val temp = File(directory, "${target.name}.${UUID.randomUUID()}.tmp")
        try {
            FileChannel.open(
                temp.toPath(),
                StandardOpenOption.CREATE_NEW,
                StandardOpenOption.WRITE,
            ).use { channel ->
                val buffer = ByteBuffer.wrap(bytes)
                while (buffer.hasRemaining()) channel.write(buffer)
                // Before the rename: after a power loss the old file must
                // still be the old file, never a renamed empty one.
                channel.force(true)
            }
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
            // Content, not length: two keys of equal length are common, so a
            // length check would bless the other writer's file.
            return Files.readAllBytes(target.toPath()).contentEquals(bytes)
        } finally {
            Files.deleteIfExists(temp.toPath())
        }
    }

    /**
     * Reads one small private file and removes it, refusing anything that is
     * not the file the caller described.
     *
     * This is the app-side form of the removal receipt reader: the same owner
     * check (0600), the same single-link check, the same size bound, and the
     * same identity comparison before the unlink. Nothing here runs a guest
     * program or interprets what it reads.
     */
    @Throws(IOException::class)
    fun readAndRemove(directory: File, name: String, maxBytes: Int): ByteArray {
        if (!SEGMENT.matches(name) || name == "." || name == "..") throw Refused("name")
        if (Files.isSymbolicLink(directory.toPath())) throw Refused("folder link")
        val path: Path = directory.toPath().resolve(name)
        val before = Files.readAttributes(
            path,
            BasicFileAttributes::class.java,
            LinkOption.NOFOLLOW_LINKS,
        )
        if (!before.isRegularFile) throw Refused("not a file")
        if (before.size() !in 1..maxBytes.toLong()) throw Refused("size")
        if (Files.getPosixFilePermissions(path, LinkOption.NOFOLLOW_LINKS) !=
            PosixFilePermissions.fromString(MODE)
        ) {
            throw Refused("mode")
        }
        val links = Files.getAttribute(path, "unix:nlink", LinkOption.NOFOLLOW_LINKS) as Int
        if (links != 1) throw Refused("links")
        val bytes = Files.newInputStream(path, LinkOption.NOFOLLOW_LINKS).use { it.readNBytes(maxBytes) }
        if (bytes.size.toLong() != before.size()) throw Refused("changed")
        // Same identity, then remove: a file swapped in between the read and
        // the unlink is left where it is, not deleted under its new owner.
        val now = Files.readAttributes(
            path,
            BasicFileAttributes::class.java,
            LinkOption.NOFOLLOW_LINKS,
        )
        if (now.fileKey() != before.fileKey()) throw Refused("replaced")
        Files.delete(path)
        return bytes
    }
}
