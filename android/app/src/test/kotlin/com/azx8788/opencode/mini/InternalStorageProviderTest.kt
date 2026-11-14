package com.azx8788.opencode.mini

import android.Manifest
import android.app.Application
import android.content.pm.ProviderInfo
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

// The Storage Access Framework root the app offers to the system file picker.
//
// The tests drive the framework entry points, not only the provider methods:
// DocumentsProvider.enforceTree() compares the granted tree id with the
// requested document id and calls isChildDocument(), so a root that only
// declares FLAG_SUPPORTS_IS_CHILD still fails here. sdk 31 is the Android
// version the picker in the reported bug runs on.
//
// The provider is attached the way the platform attaches it: exported, with
// URI grants, behind MANAGE_DOCUMENTS. The manifest itself is checked by the
// Dart test (test/android_manifest_provider_test.dart), which keeps this
// suite free of the merged resources a Robolectric manifest would need.
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31], manifest = Config.NONE, application = Application::class)
class InternalStorageProviderTest {
    @get:Rule
    val outside = TemporaryFolder()

    private lateinit var provider: InternalStorageProvider
    private lateinit var authority: String
    private lateinit var privateRoot: File
    private lateinit var testRoot: File
    private lateinit var workspace: File
    private lateinit var nested: File
    private lateinit var note: File
    private lateinit var sibling: File
    private lateinit var siblingNote: File

    @Before
    fun setUp() {
        val context = RuntimeEnvironment.getApplication()
        authority = "${context.packageName}.internalstorage"
        privateRoot = context.filesDir.canonicalFile
        testRoot = File(privateRoot, "saf-test-${UUID.randomUUID()}")
        workspace = File(testRoot, "workspace").apply { check(mkdirs()) }
        nested = File(workspace, "nested").apply { check(mkdir()) }
        note = File(nested, "note.txt").apply { writeText("hello") }
        sibling = File(testRoot, "workspace-other").apply { check(mkdir()) }
        siblingNote = File(sibling, "note.txt").apply { writeText("private sibling") }

        provider = InternalStorageProvider()
        provider.attachInfo(
            context,
            ProviderInfo().apply {
                name = InternalStorageProvider::class.java.name
                packageName = context.packageName
                this.authority = this@InternalStorageProviderTest.authority
                exported = true
                grantUriPermissions = true
                readPermission = Manifest.permission.MANAGE_DOCUMENTS
                writePermission = Manifest.permission.MANAGE_DOCUMENTS
            },
        )
    }

    @After
    fun tearDown() {
        if (::testRoot.isInitialized && testRoot.exists()) {
            // Collect first, then delete: a symlink must be removed as itself
            // and never followed out of the tree.
            val paths = Files.walk(testRoot.toPath()).use { stream ->
                stream.toList().sortedDescending()
            }
            paths.forEach { Files.delete(it) }
        }
    }

    @Test
    fun rootAdvertisesDirectoryGrantSupport() {
        provider.queryRoots(null).use { cursor ->
            assertTrue(cursor.moveToFirst())
            assertEquals(
                InternalStorageProvider.ROOT_ID,
                cursor.getString(cursor.getColumnIndexOrThrow(Root.COLUMN_DOCUMENT_ID)),
            )
            val flags = cursor.getInt(cursor.getColumnIndexOrThrow(Root.COLUMN_FLAGS))
            // Without FLAG_SUPPORTS_IS_CHILD the system directory picker hides
            // this root, which is the reported failure.
            assertTrue(flags and Root.FLAG_SUPPORTS_IS_CHILD != 0)
            assertTrue(flags and Root.FLAG_SUPPORTS_CREATE != 0)
            assertTrue(flags and Root.FLAG_LOCAL_ONLY != 0)
            assertFalse(cursor.moveToNext())
        }
    }

    @Test
    fun rootGrantContainsDirectAndNestedDocuments() {
        assertTrue(provider.isChildDocument(InternalStorageProvider.ROOT_ID, id(testRoot)))
        assertTrue(provider.isChildDocument(InternalStorageProvider.ROOT_ID, id(note)))
    }

    @Test
    fun directoryGrantContainsChildrenAndGrandchildren() {
        assertTrue(provider.isChildDocument(id(workspace), id(nested)))
        assertTrue(provider.isChildDocument(id(workspace), id(note)))
    }

    @Test
    fun directoryGrantDoesNotContainSiblingWithTheSamePrefix() {
        assertFalse(provider.isChildDocument(id(workspace), id(sibling)))
        assertFalse(provider.isChildDocument(id(workspace), id(siblingNote)))
    }

    @Test
    fun directoryAndItsAncestorsAreNotItsDescendants() {
        assertFalse(provider.isChildDocument(id(workspace), id(workspace)))
        assertFalse(provider.isChildDocument(id(workspace), id(testRoot)))
        assertFalse(provider.isChildDocument(id(workspace), InternalStorageProvider.ROOT_ID))
    }

    @Test
    fun filesAndMissingDocumentsCannotGrantChildren() {
        assertFalse(provider.isChildDocument(id(note), id(nested)))
        assertFalse(provider.isChildDocument(id(workspace), id(File(workspace, "missing"))))
        assertFalse(provider.isChildDocument(id(File(testRoot, "missing")), id(note)))
    }

    @Test
    fun traversalCannotLeaveThePrivateRoot() {
        val external = outside.newFile("outside.txt")
        val escapeId = privateRoot.toPath().relativize(external.toPath()).toString()
        assertFalse(provider.isChildDocument(InternalStorageProvider.ROOT_ID, escapeId))
        assertFalse(provider.isChildDocument(escapeId, id(note)))
    }

    @Test
    fun absolutePathCannotLeaveThePrivateRoot() {
        val external = outside.newFile("outside.txt")
        // A document id is always relative to filesDir, so an absolute path
        // cannot name a file outside it.
        assertFalse(
            provider.isChildDocument(InternalStorageProvider.ROOT_ID, external.absolutePath),
        )
        assertFalse(provider.isChildDocument(id(workspace), external.absolutePath))
    }

    @Test
    fun traversalCannotLeaveTheGrantedSubdirectory() {
        val escapeId = "${id(workspace)}/../workspace-other/note.txt"
        assertFalse(provider.isChildDocument(id(workspace), escapeId))
    }

    @Test
    fun symlinkCannotLeaveThePrivateRoot() {
        val external = outside.newFile("outside.txt")
        val link = File(workspace, "outside-link")
        Files.createSymbolicLink(link.toPath(), external.toPath())
        assertFalse(provider.isChildDocument(InternalStorageProvider.ROOT_ID, id(link)))
        assertFalse(provider.isChildDocument(id(workspace), id(link)))
    }

    @Test
    fun symlinkCannotLeaveTheGrantedSubdirectory() {
        val link = File(workspace, "sibling-link")
        Files.createSymbolicLink(link.toPath(), sibling.toPath())
        val linkedNote = File(link, "note.txt")
        assertFalse(provider.isChildDocument(id(workspace), id(linkedNote)))
        // The whole-root grant still covers it: it stays inside filesDir.
        assertTrue(provider.isChildDocument(InternalStorageProvider.ROOT_ID, id(linkedNote)))
    }

    @Test
    fun frameworkCanQueryNestedDirectoryThroughATreeGrant() {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri(workspace), id(nested))
        // ContentProvider.query() is nullable in the platform API; the
        // provider under test answers with a cursor, and a null here is a
        // failure worth naming rather than a crash inside the block.
        requireNotNull(provider.query(uri, null, null, null)).use { cursor ->
            assertTrue(cursor.moveToFirst())
            assertEquals(
                id(note),
                cursor.getString(cursor.getColumnIndexOrThrow(Document.COLUMN_DOCUMENT_ID)),
            )
            assertFalse(cursor.moveToNext())
        }
    }

    @Test
    fun frameworkCanReadAndWriteFileThroughATreeGrant() {
        val uri = documentUri(workspace, note)
        ParcelFileDescriptor.AutoCloseInputStream(provider.openFile(uri, "r")).use {
            assertEquals("hello", it.readBytes().toString(Charsets.UTF_8))
        }
        ParcelFileDescriptor.AutoCloseOutputStream(provider.openFile(uri, "wt")).use {
            it.write("updated".toByteArray(Charsets.UTF_8))
        }
        assertEquals("updated", note.readText())
    }

    @Test
    fun frameworkRefusesQueriesAndOpensOutsideTheTreeGrant() {
        val uri = documentUri(workspace, siblingNote)
        assertThrows(SecurityException::class.java) {
            provider.query(uri, null, null, null)
        }
        assertThrows(SecurityException::class.java) {
            provider.openFile(uri, "r")
        }
    }

    @Test
    fun newlyCreatedDocumentIsAccessibleThroughTheTreeGrant() {
        val createdId = provider.createDocument(id(workspace), "text/plain", "created.txt")
        assertTrue(provider.isChildDocument(id(workspace), createdId))
        val uri = DocumentsContract.buildDocumentUriUsingTree(treeUri(workspace), createdId)
        requireNotNull(provider.query(uri, null, null, null)).use { cursor ->
            assertTrue(cursor.moveToFirst())
            assertEquals(
                "created.txt",
                cursor.getString(cursor.getColumnIndexOrThrow(Document.COLUMN_DISPLAY_NAME)),
            )
        }
    }

    private fun id(file: File): String =
        if (file == privateRoot) InternalStorageProvider.ROOT_ID
        else file.relativeTo(privateRoot).invariantSeparatorsPath

    private fun treeUri(parent: File): Uri = DocumentsContract.buildTreeDocumentUri(authority, id(parent))

    private fun documentUri(parent: File, child: File): Uri =
        DocumentsContract.buildDocumentUriUsingTree(treeUri(parent), id(child))
}
