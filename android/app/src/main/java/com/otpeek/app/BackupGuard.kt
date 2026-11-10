package com.otpeek.app

import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Resource preflight only; authentication/decryption remains in the Rust vault. */
object BackupGuard {
    const val MAX_BYTES = 8 * 1024 * 1024
    fun check(data: ByteArray): Boolean {
        require(data.size in 16..MAX_BYTES) { "Invalid backup size" }
        if (data.copyOfRange(0, 4).contentEquals("OTPB".toByteArray())) {
            require(data.size >= 68 && word(data, 4) == 1) { "Invalid legacy backup" }
            return true
        }
        require(data.copyOfRange(0, 8).contentEquals("OTPVAULT".toByteArray())) { "Invalid backup format" }
        require(word(data, 8) == 2) { "Unsupported backup version" }
        val length = word(data, 12)
        require(length in 1..65536 && length.toLong() + 32 <= data.size) { "Invalid header" }
        val header = JSONObject(String(data, 16, length, Charsets.UTF_8))
        val kdf = header.getJSONObject("kdf")
        require(kdf.getString("algo") == "argon2id") { "Unsupported KDF" }
        // Bound unauthenticated cost fields before passing the blob to Rust.
        require(kdf.getLong("mKib") in 8L..131072L) { "Backup memory cost too high" }
        require(kdf.getLong("t") in 1L..6L && kdf.getLong("p") in 1L..4L) { "Backup cost unsupported" }
        return false
    }

    private fun word(data: ByteArray, offset: Int) =
        ByteBuffer.wrap(data, offset, 4).order(ByteOrder.LITTLE_ENDIAN).int
}
