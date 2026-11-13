package com.azx8788.opencode.mini

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileNotFoundException

/**
 * The Storage Access Framework root the app offers to the system file picker.
 *
 * It exposes the app's private files directory (filesDir) as a browsable
 * document tree with read and write access, so a third-party file manager the
 * person authorizes through the SAF picker can open, copy, rename, create and
 * delete everything under filesDir: logs, diagnostics, the in-app Linux tree
 * and the rest. Nothing is filtered by name.
 *
 * Every document id is a path relative to filesDir; "root" is filesDir
 * itself. resolve() canonicalizes the id and refuses anything outside
 * filesDir, so a crafted id cannot climb out of the app's private storage.
 *
 * The manifest registers this provider with
 * android:permission="android.permission.MANAGE_DOCUMENTS": only the system
 * documents UI can query it directly, and a file manager reaches it through
 * the standard picker, which is the system asking the person to grant access.
 */
class InternalStorageProvider : DocumentsProvider() {

    override fun onCreate(): Boolean = true

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(DEFAULT_ROOT_PROJECTION)
        val row = cursor.newRow()
        row.add(Root.COLUMN_ROOT_ID, ROOT_ID)
        row.add(Root.COLUMN_DOCUMENT_ID, ROOT_ID)
        row.add(Root.COLUMN_TITLE, "OpenCode Plus")
        row.add(Root.COLUMN_SUMMARY, "The app's private files")
        row.add(Root.COLUMN_FLAGS, Root.FLAG_LOCAL_ONLY or Root.FLAG_SUPPORTS_CREATE)
        row.add(Root.COLUMN_ICON, R.mipmap.ic_launcher)
        return cursor
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(DEFAULT_DOCUMENT_PROJECTION)
        includeFile(cursor, documentId, resolve(documentId))
        return cursor
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val cursor = MatrixCursor(DEFAULT_DOCUMENT_PROJECTION)
        val parent = resolve(parentDocumentId)
        val children = parent.listFiles()
        if (children != null) {
            for (child in children) {
                // The id is the resolved parent's id plus a direct child
                // name, so it cannot climb out; symlink targets are checked
                // when a document is opened or created.
                val childId = childIdOf(parentDocumentId, child.name)
                includeFile(cursor, childId, child)
            }
        }
        return cursor
    }

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor {
        val file = resolve(documentId)
        if (file.isDirectory) throw FileNotFoundException("Not a file: $documentId")
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.parseMode(mode))
    }

    override fun createDocument(
        parentDocumentId: String,
        mimeType: String,
        displayName: String,
    ): String {
        val parent = resolve(parentDocumentId)
        if (!parent.isDirectory) throw FileNotFoundException("Not a directory: $parentDocumentId")
        val target = File(parent, safeName(displayName))
        val created = if (mimeType == Document.MIME_TYPE_DIR) {
            target.mkdir() || target.isDirectory
        } else {
            target.createNewFile() || target.isFile
        }
        if (!created) throw FileNotFoundException("Could not create ${target.name}")
        return childIdOf(parentDocumentId, target.name)
    }

    override fun deleteDocument(documentId: String) {
        val file = resolve(documentId)
        if (file == root()) throw FileNotFoundException("Cannot delete the root")
        deleteRecursively(file)
        revokeDocumentPermission(documentId)
    }

    override fun renameDocument(documentId: String, displayName: String): String? {
        val file = resolve(documentId)
        if (file == root()) throw FileNotFoundException("Cannot rename the root")
        val target = File(file.parentFile, safeName(displayName))
        if (!file.renameTo(target)) throw FileNotFoundException("Could not rename $displayName")
        revokeDocumentPermission(documentId)
        return childIdOf(parentIdOf(documentId), target.name)
    }

    private fun root(): File = requireNotNull(context).filesDir.canonicalFile

    private fun resolve(documentId: String): File {
        val base = root()
        if (documentId == ROOT_ID) return base
        val file = File(base, documentId).canonicalFile
        val prefix = base.path + File.separator
        if (file.path != base.path && !file.path.startsWith(prefix)) {
            throw FileNotFoundException("Outside the app's files directory")
        }
        return file
    }

    private fun childIdOf(parentDocumentId: String, name: String): String =
        if (parentDocumentId == ROOT_ID) name else "$parentDocumentId/$name"

    private fun parentIdOf(documentId: String): String {
        val cut = documentId.lastIndexOf('/')
        return if (cut <= 0) ROOT_ID else documentId.substring(0, cut)
    }

    private fun includeFile(cursor: MatrixCursor, documentId: String, file: File) {
        val isDir = file.isDirectory
        val row = cursor.newRow()
        row.add(Document.COLUMN_DOCUMENT_ID, documentId)
        row.add(
            Document.COLUMN_DISPLAY_NAME,
            if (documentId == ROOT_ID) "OpenCode Plus" else file.name,
        )
        row.add(Document.COLUMN_SIZE, if (isDir) 0L else file.length())
        row.add(
            Document.COLUMN_MIME_TYPE,
            if (isDir) Document.MIME_TYPE_DIR else mimeTypeOf(file),
        )
        row.add(Document.COLUMN_LAST_MODIFIED, file.lastModified())
        row.add(
            Document.COLUMN_FLAGS,
            when {
                // The root can gain children but cannot itself be removed or
                // renamed, so those flags stay off it.
                documentId == ROOT_ID -> Document.FLAG_DIR_SUPPORTS_CREATE
                isDir ->
                    Document.FLAG_DIR_SUPPORTS_CREATE or
                        Document.FLAG_SUPPORTS_DELETE or
                        Document.FLAG_SUPPORTS_RENAME
                else ->
                    Document.FLAG_SUPPORTS_WRITE or
                        Document.FLAG_SUPPORTS_DELETE or
                        Document.FLAG_SUPPORTS_RENAME
            },
        )
    }

    private fun mimeTypeOf(file: File): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase())
            ?: "application/octet-stream"

    private fun safeName(name: String): String {
        val trimmed = name.trim()
        if (trimmed.isEmpty() || trimmed == "." || trimmed == ".." ||
            trimmed.contains('/') || trimmed.contains('\u0000')
        ) {
            throw FileNotFoundException("Invalid name")
        }
        return trimmed
    }

    private fun deleteRecursively(file: File) {
        // A link is removed itself, never followed: deleting a rootfs link
        // such as /bin must not wipe the directory it points at.
        if (isLink(file)) {
            if (!file.delete()) throw FileNotFoundException("Could not delete ${file.name}")
            return
        }
        if (file.isDirectory) {
            file.listFiles()?.forEach { deleteRecursively(it) }
        }
        if (!file.delete()) throw FileNotFoundException("Could not delete ${file.name}")
    }

    private fun isLink(file: File): Boolean = try {
        OsConstants.S_ISLNK(Os.lstat(file.path).st_mode)
    } catch (_: ErrnoException) {
        false
    }

    companion object {
        /** The document id of filesDir itself; StorageAccess opens the picker
         *  at this root. */
        const val ROOT_ID = "root"

        private val DEFAULT_ROOT_PROJECTION = arrayOf(
            Root.COLUMN_ROOT_ID,
            Root.COLUMN_DOCUMENT_ID,
            Root.COLUMN_TITLE,
            Root.COLUMN_SUMMARY,
            Root.COLUMN_FLAGS,
            Root.COLUMN_ICON,
        )

        private val DEFAULT_DOCUMENT_PROJECTION = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_SIZE,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_FLAGS,
        )
    }
}