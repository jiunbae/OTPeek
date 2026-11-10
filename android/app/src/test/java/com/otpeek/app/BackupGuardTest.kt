package com.otpeek.app

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class BackupGuardTest {
    private fun fixture(memory: Long = 65536, time: Long = 3, parallel: Long = 1): ByteArray {
        val header = """{"kdf":{"algo":"argon2id","mKib":$memory,"t":$time,"p":$parallel}}""".toByteArray()
        return ByteBuffer.allocate(16 + header.size + 16).order(ByteOrder.LITTLE_ENDIAN)
            .put("OTPVAULT".toByteArray()).putInt(2).putInt(header.size).put(header).put(ByteArray(16)).array()
    }
    @Test fun acceptedCoreCosts() { assertFalse(BackupGuard.check(fixture())) }
    @Test fun legacyDispatch() {
        val data = ByteBuffer.allocate(68).order(ByteOrder.LITTLE_ENDIAN).put("OTPB".toByteArray()).putInt(1).array()
        assertTrue(BackupGuard.check(data))
    }
    @Test fun untrustedCostsRejectedBeforeRust() {
        listOf(fixture(memory = 4294967295), fixture(time = 2147483647), fixture(parallel = 256)).forEach {
            assertThrows(IllegalArgumentException::class.java) { BackupGuard.check(it) }
        }
    }
    @Test fun oversizeAndTruncatedRejected() {
        assertThrows(IllegalArgumentException::class.java) { BackupGuard.check(ByteArray(BackupGuard.MAX_BYTES + 1)) }
        assertThrows(IllegalArgumentException::class.java) { BackupGuard.check(fixture().copyOf(18)) }
    }
}
