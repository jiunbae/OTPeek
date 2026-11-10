package com.otpeek.app

import android.content.Context
import android.content.ContextWrapper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.otpeek.HashAlgorithm
import java.io.File
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator

@RunWith(AndroidJUnit4::class)
class StorageSafetyTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private fun fixtureContext(dir: File) = object : ContextWrapper(context) {
        override fun getNoBackupFilesDir() = dir
    }
    @Test fun stagedRestoreFailureKeepsExistingVaultAndCounter() {
        val dir = File(context.noBackupFilesDir, "fixture-${UUID.randomUUID()}").apply { mkdirs() }
        val repo = VaultRepository(fixtureContext(dir))
        try {
            repo.create("fixture-master")
            repo.addManual("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", "RFC", "fixture", true, HashAlgorithm.SHA1, 6u, 30u, 0uL)
            val id = repo.rows(0).single().id
            val backup = repo.export("fixture-backup")
            repo.nextHotp(id)
            val pointer = File(dir, "otpeek/active").readText()
            assertThrows(Exception::class.java) { repo.restore(backup, "wrong", false) }
            assertEquals(pointer, File(dir, "otpeek/active").readText())
            assertEquals(1uL, repo.rows(0).single().counter)
            repo.restore(backup, "fixture-backup", true)
            assertEquals(1uL, repo.rows(0).single().counter)
            repo.lock()
            repo.open("fixture-master")
            assertEquals(1uL, repo.rows(0).single().counter)
            repo.restore(backup, "fixture-backup", false)
            assertEquals(0uL, repo.rows(0).single().counter)
        } finally { repo.lock(); dir.deleteRecursively() }
    }
    @Test fun hardwareWrappingAndLostKeyPreservePasswordRecovery() {
        val dir = File(context.noBackupFilesDir, "fixture-${UUID.randomUUID()}").apply { mkdirs() }
        val repo = VaultRepository(fixtureContext(dir))
        val alias = "otpeek-fixture-${UUID.randomUUID()}"
        try {
            repo.create("fixture-master")
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            // Fixture key has no interactive auth, so unattended tests can exercise wrapping.
            // Production VaultKeyStore.encryption() always requires authentication.
            generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            val key = generator.generateKey()
            assertNull(key.encoded)
            val vmk = repo.vaultKey()
            try {
                val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key) }
                val file = repo.wrappingFile()
                VaultKeyStore.save(file, alias, cipher, vmk)
                repo.lock()
                val unwrapped = VaultKeyStore.unwrap(file, VaultKeyStore.decryption(file))
                try { assertTrue(vmk.contentEquals(unwrapped)); repo.openKey(unwrapped) }
                finally { unwrapped.fill(0) }
                repo.addUri("otpauth://totp/QR-fixture?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
                assertTrue(repo.biometricEnabled)
                val retainedFile = repo.wrappingFile()
                VaultKeyStore.deleteAlias(alias)
                repo.lock()
                assertThrows(DeviceKeyUnavailable::class.java) { VaultKeyStore.decryption(retainedFile) }
                repo.open("fixture-master")
                assertTrue(repo.unlocked)
            } finally { vmk.fill(0) }
        } finally { repo.lock(); VaultKeyStore.deleteAlias(alias); dir.deleteRecursively() }
    }
    @Test fun failedHotpPersistenceLocksWithoutReturningConsumedCode() {
        val dir = File(context.noBackupFilesDir, "fixture-${UUID.randomUUID()}").apply { mkdirs() }
        val repo = VaultRepository(fixtureContext(dir))
        var active: File? = null
        try {
            repo.create("fixture-master")
            repo.addManual("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", "RFC", "fixture", true, HashAlgorithm.SHA1, 6u, 30u, 0uL)
            val id = repo.rows(0).single().id
            active = File(dir, "otpeek/" + File(dir, "otpeek/active").readText())
            android.system.Os.chmod(active.absolutePath, 320) // owner read/execute, no new temp file
            assertThrows(Exception::class.java) { repo.nextHotp(id) }
            assertFalse(repo.unlocked)
            android.system.Os.chmod(active.absolutePath, 448)
            repo.open("fixture-master")
            assertEquals(0uL, repo.rows(0).single().counter)
            assertTrue(repo.rows(0).single().code.isEmpty())
            repo.addManual("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", "RFC", "exhausted", true,
                HashAlgorithm.SHA1, 6u, 30u, ULong.MAX_VALUE)
            val exhausted = repo.rows(0).first { it.counter == ULong.MAX_VALUE }
            assertThrows(IllegalArgumentException::class.java) { repo.nextHotp(exhausted.id) }
            assertTrue(repo.unlocked)
        } finally {
            active?.let { android.system.Os.chmod(it.absolutePath, 448) }
            repo.lock(); dir.deleteRecursively()
        }
    }
}
