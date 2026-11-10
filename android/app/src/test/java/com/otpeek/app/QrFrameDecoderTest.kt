package com.otpeek.app

import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer

class QrFrameDecoderTest {
    @Test fun paddedOffsetAndPixelStrideFramesDecodePublicFixture() {
        val text = "otpauth://totp/RFC?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        val qr = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 240, 240)
        for (pixelStride in listOf(1, 2)) {
            val stride = 240 * pixelStride + 17
            val buffer = ByteBuffer.allocate(11 + stride * 240)
            for (y in 0 until 240) for (x in 0 until 240) buffer.put(11 + y * stride + x * pixelStride, if (qr[x, y]) 0 else 255.toByte())
            buffer.position(11)
            assertEquals(text, QrFrameDecoder().decode(buffer, 240, 240, stride, pixelStride))
            assertEquals(11, buffer.position())
        }
    }
    @Test fun malformedAndBlankFramesDoNotCrashAnalyzer() {
        val decoder = QrFrameDecoder()
        val tiny = ByteBuffer.allocate(10)
        assertNull(decoder.decode(tiny, 240, 240, 240, 1))
        assertNull(decoder.decode(tiny, 1, -1, 1, 1))
        assertNull(decoder.decode(tiny, Int.MAX_VALUE, Int.MAX_VALUE, Int.MAX_VALUE, 2))
        assertNull(decoder.decode(tiny, 10, 1, 5, 1))
        assertNull(decoder.decode(ByteBuffer.allocate(240 * 240), 240, 240, 240, 1))
    }
}
