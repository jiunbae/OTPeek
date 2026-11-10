package com.otpeek.app

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class DeviceKeyUnavailable : Exception()

/** Keystore key wraps the VMK; existing Rust AES/Argon2 vault format is unchanged. */
object VaultKeyStore {
    private fun store() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    fun encryption(): Pair<String, Cipher> {
        val alias = "otpeek-vmk-${UUID.randomUUID()}"
        val builder = KeyGenParameterSpec.Builder(alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setUserAuthenticationRequired(true)
        if (Build.VERSION.SDK_INT >= 30) {
            builder.setUserAuthenticationParameters(0,
                KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL)
        } else {
            @Suppress("DEPRECATION")
            builder.setUserAuthenticationValidityDurationSeconds(-1)
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(builder.build())
        val key = generator.generateKey()
        return alias to Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key) }
    }
    fun save(file: File, alias: String, cipher: Cipher, vmk: ByteArray) {
        val previous = readAlias(file)
        val data = JSONObject().put("alias", alias).put("iv", encode(cipher.iv))
            .put("ciphertext", encode(cipher.doFinal(vmk)))
        VaultRepository.atomicWrite(AtomicFile(file), data.toString().toByteArray())
        if (previous != null && previous != alias) deleteAlias(previous)
    }
    fun decryption(file: File): Cipher = try {
        val data = JSONObject(AtomicFile(file).readFully().toString(Charsets.UTF_8))
        val key = store().getKey(data.getString("alias"), null) as? SecretKey ?: throw DeviceKeyUnavailable()
        Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, decode(data.getString("iv"))))
        }
    } catch (_: Exception) { throw DeviceKeyUnavailable() }
    fun unwrap(file: File, cipher: Cipher): ByteArray = try {
        val data = JSONObject(AtomicFile(file).readFully().toString(Charsets.UTF_8))
        cipher.doFinal(decode(data.getString("ciphertext")))
    } catch (_: Exception) { throw DeviceKeyUnavailable() }
    fun remove(file: File) {
        readAlias(file)?.let { deleteAlias(it) }
        AtomicFile(file).delete()
    }
    fun deleteAlias(alias: String) { store().deleteEntry(alias) }
    private fun readAlias(file: File): String? = try {
        JSONObject(AtomicFile(file).readFully().toString(Charsets.UTF_8)).getString("alias")
    } catch (_: Exception) { null }
    private fun encode(data: ByteArray) = Base64.encodeToString(data, Base64.NO_WRAP)
    private fun decode(data: String) = Base64.decode(data, Base64.NO_WRAP)
}
