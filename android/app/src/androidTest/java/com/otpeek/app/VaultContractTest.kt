package com.otpeek.app

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.otpeek.*
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class VaultContractTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private fun isolated(): File = File(context.noBackupFilesDir, "fixture-${UUID.randomUUID()}").apply { mkdirs() }

    @Test fun nativeRfcBackupAndReopen() {
        val dir = isolated()
        try {
            val path = File(dir, "vault.otpvault").absolutePath
            val client = OtpClient.create(path, "fixture-master")
            try {
                val account = client.addFromUri("otpauth://hotp/RFC?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&counter=0").single()
                assertEquals("755224", client.code(account.id, 0).code)
                assertEquals("755224", client.nextHotp(account.id).code)
                val key = client.vaultKey()
                try {
                    OtpClient.openWithKey(path, key).use { assertEquals(1uL, it.getAccount(account.id)?.counter) }
                } finally { key.fill(0) }
                val backup = client.exportBackup("fixture-backup")
                assertFalse(BackupGuard.check(backup))
                OtpClient.restore(File(dir, "restored.otpvault").absolutePath, backup, "fixture-backup").use {
                    assertEquals("287082", it.code(account.id, 0).code)
                    assertTrue(it.vaultKey().contentEquals(client.vaultKey()).not())
                }
                assertThrows(OtpException.WrongPassword::class.java) { client.importBackup(backup, "wrong", false) }
                assertEquals(1uL, client.getAccount(account.id)?.counter)
                assertEquals("94287082", generateTotpNow("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", HashAlgorithm.SHA1, 8u, 30u, 59))
            } finally { client.close() }
        } finally { dir.deleteRecursively() }
    }

    @Test fun committedCrossPlatformFixtureLoads() {
        val dir = isolated()
        try {
            val bytes = InstrumentationRegistry.getInstrumentation().context.assets.open("vault-v2.otpvault").use { it.readBytes() }
            assertFalse(BackupGuard.check(bytes))
            OtpClient.restore(File(dir, "fixture.otpvault").absolutePath, bytes, "test-password-123").use {
                assertTrue(it.listAccounts().isNotEmpty())
            }
        } finally { dir.deleteRecursively() }
    }
    @Test fun googleMigrationUsesExistingRustParser() {
        val dir = isolated()
        try {
            val uri = InstrumentationRegistry.getInstrumentation().context.assets
                .open("google-migration-fixture.uri").bufferedReader().use { it.readText().trim() }
            OtpClient.create(File(dir, "migration.otpvault").absolutePath, "fixture-master").use {
                val a = it.addFromUri(uri).single()
                assertEquals("RFC", a.issuer)
                assertEquals("migration fixture", a.accountName)
                assertEquals(OtpType.TOTP, a.otpType)
                assertEquals("755224", it.code(a.id, 0).code)
            }
        } finally { dir.deleteRecursively() }
    }
}
