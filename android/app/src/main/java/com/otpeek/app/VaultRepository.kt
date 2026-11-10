package com.otpeek.app

import android.content.Context
import android.util.AtomicFile
import uniffi.otpeek.*
import java.io.File
import java.util.UUID

data class AccountRow(
    val id: String,
    val issuer: String,
    val name: String,
    val hotp: Boolean,
    val counter: ULong,
    val code: String,
    val validUntil: Long,
)

/** All calls are serialized by VaultViewModel. No platform OTP or vault crypto. */
class VaultRepository(context: Context) {
    private val root = File(context.noBackupFilesDir, "otpeek").apply { mkdirs() }
    private val activeFile = AtomicFile(File(root, "active"))
    private var client: OtpClient? = null
    private val consumedCodes = mutableMapOf<String, OtpCode>()
    val exists: Boolean get() = activeDirectory()?.let { File(it, "vault.otpvault").isFile } == true
    val unlocked: Boolean get() = client != null
    val biometricEnabled: Boolean get() = activeDirectory()?.let { File(it, "wrapped-vmk").isFile } == true
    fun wrappingFile(): File = File(requireNotNull(activeDirectory()), "wrapped-vmk")

    private fun activeDirectory(): File? = try {
        val id = activeFile.readFully().toString(Charsets.UTF_8)
        UUID.fromString(id)
        File(root, id)
    } catch (_: Exception) { null }

    private fun path(dir: File) = File(dir, "vault.otpvault").absolutePath
    private fun current() = checkNotNull(client) { "Vault locked" }
    fun lock() {
        client?.close()
        client = null
        consumedCodes.clear()
    }
    fun open(password: String) {
        val dir = requireNotNull(activeDirectory())
        BackupGuard.check(File(path(dir)).readBytes())
        val opened = OtpClient.openWithPassword(path(dir), password)
        try { validate(opened) } catch (e: Exception) { opened.close(); throw e }
        lock()
        client = opened
    }
    fun openKey(key: ByteArray) {
        val opened = OtpClient.openWithKey(path(requireNotNull(activeDirectory())), key)
        try { validate(opened) } catch (e: Exception) { opened.close(); throw e }
        lock()
        client = opened
    }
    fun create(password: String) {
        check(!exists) { "Vault already exists" }
        require(password.length >= 10)
        stage { dir -> OtpClient.create(path(dir), password) }
    }
    fun restore(data: ByteArray, password: String, merge: Boolean, newMaster: String = "") {
        val legacy = BackupGuard.check(data)
        val previous = activeDirectory()
        stage { dir ->
            val opened = if (previous != null) {
                File(path(previous)).copyTo(File(path(dir)))
                val key = current().vaultKey()
                try { OtpClient.openWithKey(path(dir), key) } finally { key.fill(0) }
            } else if (legacy) {
                require(newMaster.length >= 10)
                OtpClient.create(path(dir), newMaster)
            } else OtpClient.restore(path(dir), data, password)
            try {
                if (previous != null || legacy) {
                    if (legacy) opened.importBackupV1(data, password, merge)
                    else opened.importBackup(data, password, merge)
                }
                opened
            } catch (e: Exception) { opened.close(); throw e }
        }
    }
    private fun stage(preserveWrapping: Boolean = false, factory: (File) -> OtpClient) {
        val dir = File(root, UUID.randomUUID().toString()).apply { check(mkdir()) }
        var opened: OtpClient? = null
        var activated = false
        try {
            opened = factory(dir)
            validate(opened)
            val old = activeDirectory()
            if (preserveWrapping && old != null) {
                File(old, "wrapped-vmk").takeIf { it.isFile }?.copyTo(File(dir, "wrapped-vmk"))
            }
            atomicWrite(activeFile, dir.name.toByteArray())
            activated = true
            lock()
            client = opened
            old?.let {
                if (!preserveWrapping) VaultKeyStore.remove(File(it, "wrapped-vmk"))
                it.deleteRecursively()
            }
        } finally {
            if (!activated) { opened?.close(); dir.deleteRecursively() }
        }
    }
    fun rows(now: Long): List<AccountRow> = current().listAccounts().map { a ->
        val code = if (a.otpType == OtpType.HOTP) consumedCodes[a.id]
                   else current().code(a.id, now)
        AccountRow(a.id, a.issuer.orEmpty(), a.accountName, a.otpType == OtpType.HOTP,
            a.counter, code?.code.orEmpty(), code?.validUntil ?: Long.MAX_VALUE)
    }
    fun addManual(secret: String, issuer: String, name: String, hotp: Boolean,
                  algorithm: HashAlgorithm, digits: UInt, period: UInt, counter: ULong) {
        require(name.isNotBlank())
        val a = OtpAccount("", if (hotp) OtpType.HOTP else OtpType.TOTP, secret,
            issuer.ifBlank { null }, name, algorithm, digits, period, counter, null,
            false, 0, null, null, 0, 0, null)
        checkAccount(a)
        mutate { it.addAccount(a) }
    }
    fun addUri(uri: String) {
        require(uri.length <= 65536)
        require(uri.startsWith("otpauth://") || uri.startsWith("otpauth-migration://offline?"))
        if (uri.startsWith("otpauth://")) checkAccount(parseOtpauthUri(uri, System.currentTimeMillis()))
        // Staging prevents an invalid migration model from becoming the active vault.
        val dir = requireNotNull(activeDirectory())
        val key = current().vaultKey()
        try {
            stage(preserveWrapping = true) { next ->
                File(path(dir)).copyTo(File(path(next)))
                OtpClient.openWithKey(path(next), key).also { opened ->
                    try { opened.addFromUri(uri) } catch (e: Exception) { opened.close(); throw e }
                }
            }
        } finally { key.fill(0) }
    }
    fun nextHotp(id: String) {
        require(current().getAccount(id)?.counter != ULong.MAX_VALUE) { "Counter exhausted" }
        mutate { consumedCodes[id] = it.nextHotp(id) }
    }
    fun delete(id: String) { mutate { it.deleteAccount(id) }; consumedCodes.remove(id) }
    fun export(password: String): ByteArray {
        require(password.length >= 10)
        return current().exportBackup(password)
    }
    fun vaultKey(): ByteArray = current().vaultKey()
    private fun mutate(action: (OtpClient) -> Unit) {
        try { action(current()) } catch (e: Exception) {
            // Rust mutations don't roll back on persistence failure. Force reauthentication.
            lock()
            throw e
        }
    }
    private fun validate(c: OtpClient) {
        val accounts = c.listAccounts()
        require(accounts.size <= 10000 && accounts.map { it.id }.distinct().size == accounts.size)
        accounts.forEach { checkAccount(it); c.code(it.id, System.currentTimeMillis()) }
    }
    private fun checkAccount(a: OtpAccount) {
        require(validateSecret(a.secret))
        require(a.digits in 6u..8u && a.period > 0u)
    }
    companion object {
        fun atomicWrite(file: AtomicFile, bytes: ByteArray) {
            val stream = file.startWrite()
            try { stream.write(bytes); file.finishWrite(stream) }
            catch (e: Exception) { file.failWrite(stream); throw e }
        }
    }
}
