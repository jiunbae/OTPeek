package com.otpeek.app

import android.app.Application
import android.content.Context
import android.net.Uri
import android.os.SystemClock
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import uniffi.otpeek.HashAlgorithm
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

class DocumentRecoveryTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val resolver = context.contentResolver
    private val authority = Uri.parse("content://com.otpeek.app.debug.test.fixtures")
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val models = mutableListOf<Pair<VaultViewModel, Pair<ViewModelStore, File>>>()
    private val documents = mutableListOf<String>()
    private fun uri(kind: String = "normal"): Uri {
        val id = UUID.randomUUID().toString(); documents += id
        return authority.buildUpon().appendPath(kind).appendPath(id).build()
    }
    private fun model(): VaultViewModel {
        val root = File(context.cacheDir, "fixture-model-${UUID.randomUUID()}").apply { mkdirs() }
        val app = object : Application() {
            init { attachBaseContext(context) }
            override fun getNoBackupFilesDir() = root
        }
        val model = VaultViewModel(app)
        val store = ViewModelStore().apply { put("fixture", model) }
        models += model to (store to root)
        return model
    }
    private fun await(condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 60000
        while (!condition() && SystemClock.uptimeMillis() < deadline) Thread.sleep(20)
        assertTrue("Fixture operation timed out", condition())
    }
    private fun run(model: VaultViewModel, action: () -> Unit) {
        instrumentation.runOnMainSync(action)
        await { !model.state.value.busy }
    }
    private fun write(uri: Uri, bytes: ByteArray) { resolver.openOutputStream(uri, "wt")!!.use { it.write(bytes) } }
    private fun pointer(model: VaultViewModel): String {
        val root = models.first { it.first === model }.second.second
        return File(root, "otpeek/active").readText()
    }
    @After fun cleanup() {
        documents.forEach { resolver.call(authority, "release", it, null) }
        models.forEach { (model, pair) ->
            instrumentation.runOnMainSync { pair.first.clear() }
            await { !model.repository.unlocked }
            pair.second.deleteRecursively()
        }
        documents.forEach { resolver.call(authority, "delete", it, null) }
    }
    @Test fun encryptedDocumentRoundTripAndFailedRestorePreserveVault() {
        val original = model()
        run(original) { original.create("fixture-master") }
        run(original) { original.addUri("otpauth://hotp/RFC?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&counter=0") }
        val document = uri()
        run(original) { original.export(document, "fixture-master", "fixture-backup") }
        Thread.sleep(1300) // OTP refresh must not erase the user's backup result.
        assertEquals(context.getString(R.string.exported), original.state.value.message)
        val bytes = resolver.openInputStream(document)!!.use { it.readBytes() }
        assertFalse(BackupGuard.check(bytes))
        assertFalse(String(bytes, Charsets.ISO_8859_1).contains("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"))
        val restored = model()
        run(restored) { restored.restore(document, "fixture-backup", "", true, "") }
        assertTrue(restored.state.value.unlocked)
        run(restored) { restored.next(restored.state.value.rows.single().id) }
        assertEquals("755224", restored.state.value.rows.single().code)
        val active = pointer(restored)
        run(restored) { restored.restore(document, "wrong", "", false, "") }
        assertEquals(active, pointer(restored))
        assertEquals(1uL, restored.state.value.rows.single().counter)
        run(restored) { restored.lock() }
        run(restored) { restored.open("fixture-backup") }
        assertTrue(restored.state.value.unlocked)
        assertEquals(1uL, restored.state.value.rows.single().counter)
        bytes.fill(0)
    }
    @Test fun legacyDocumentRequiresNewMasterAndRetainsExistingMaster() {
        val document = uri(); write(document, legacyFixture())
        val fresh = model()
        run(fresh) { fresh.restore(document, "wrong", "", true, "fixture-new-master") }
        assertFalse(fresh.state.value.exists)
        run(fresh) { fresh.restore(document, "fixture-legacy", "", true, "fixture-new-master") }
        assertTrue(fresh.state.value.unlocked)
        run(fresh) { fresh.lock() }
        run(fresh) { fresh.open("fixture-new-master") }
        run(fresh) { fresh.next(fresh.state.value.rows.single().id) }
        assertEquals("755224", fresh.state.value.rows.single().code)
        run(fresh) { fresh.restore(document, "fixture-legacy", "", false, "") }
        assertEquals(0uL, fresh.state.value.rows.single().counter)
        run(fresh) { fresh.lock() }
        run(fresh) { fresh.open("fixture-new-master") }
        assertTrue(fresh.state.value.unlocked)
    }
    @Test fun failedAndPartialProviderWritesNeverReportExportSuccess() {
        val model = model()
        run(model) { model.create("fixture-master") }
        run(model) { model.addManual("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", "fixture".repeat(200000), "RFC", true, HashAlgorithm.SHA1, 6u, 30u, 0uL) }
        val active = pointer(model)
        for (kind in listOf("full", "partial")) {
            val document = uri(kind)
            run(model) { model.export(document, "fixture-master", "fixture-backup") }
            assertEquals(context.getString(R.string.operation_failed), model.state.value.message)
            assertEquals(active, pointer(model))
            assertEquals(0uL, model.state.value.rows.single().counter)
        }
        assertTrue(resolver.call(authority, "received", null, null)!!.getInt("received") > 0)
    }
    @Test fun lockDuringBlockedDocumentReadPreventsRestoreCommit() {
        val source = model()
        run(source) { source.create("fixture-source") }
        run(source) { source.addUri("otpauth://totp/RFC?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ") }
        val normal = uri()
        run(source) { source.export(normal, "fixture-source", "fixture-backup") }
        val slow = normal.buildUpon().path("slow/${normal.lastPathSegment}").build()
        val target = model()
        run(target) { target.create("fixture-target") }
        val active = pointer(target)
        instrumentation.runOnMainSync { target.restore(slow, "fixture-backup", "", false, "") }
        await { resolver.call(authority, "waiting", slow.lastPathSegment, null)!!.getBoolean("waiting") }
        instrumentation.runOnMainSync { target.lock() }
        resolver.call(authority, "release", slow.lastPathSegment, null)
        run(target) { target.open("fixture-target") }
        assertTrue(target.state.value.unlocked)
        assertEquals(active, pointer(target))
        assertTrue(target.state.value.rows.isEmpty())
    }
    /** Test data encryption only. The production app delegates backup crypto to Rust. */
    private fun legacyFixture(): ByteArray {
        val payload = """{"version":1,"exportedAt":"2024-01-01T12:00:00Z","accounts":[{"type":"hotp","secret":"GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ","accountName":"RFC fixture","counter":0}],"folders":[]}""".toByteArray()
        val salt = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
        val nonce = ByteArray(12).also { java.security.SecureRandom().nextBytes(it) }
        val spec = PBEKeySpec("fixture-legacy".toCharArray(), salt, 100000, 256)
        val key = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        try {
            val encrypted = Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            }.doFinal(payload)
            return ByteBuffer.allocate(68 + encrypted.size - 16).order(ByteOrder.LITTLE_ENDIAN)
                .put("OTPB".toByteArray()).putInt(1).put(salt).put(nonce)
                .put(encrypted, encrypted.size - 16, 16).put(encrypted, 0, encrypted.size - 16).array()
        } finally { key.fill(0); spec.clearPassword() }
    }
}
