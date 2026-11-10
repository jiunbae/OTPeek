package com.otpeek.app

import com.google.zxing.*
import com.google.zxing.common.HybridBinarizer
import java.nio.ByteBuffer

/** Camera plane layout only; OTP URI parsing stays in Rust. Used on one analyzer thread. */
class QrFrameDecoder {
    private val reader = MultiFormatReader().apply {
        setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE), DecodeHintType.TRY_HARDER to true))
    }
    fun decode(buffer: ByteBuffer, width: Int, height: Int, rowStride: Int, pixelStride: Int): String? {
        if (width <= 0 || height <= 0 || pixelStride <= 0 || rowStride <= 0 ||
            width.toLong() * height > 16 * 1024 * 1024 ||
            (width - 1L) * pixelStride + 1 > rowStride) return null
        val required = (height - 1L) * rowStride + (width - 1L) * pixelStride + 1
        if (required > buffer.remaining()) return null
        val start = buffer.position()
        val bytes = ByteArray(width * height)
        for (y in 0 until height) for (x in 0 until width) {
            bytes[y * width + x] = buffer.get(start + y * rowStride + x * pixelStride)
        }
        val source = PlanarYUVLuminanceSource(bytes, width, height, 0, 0, width, height, false)
        return try {
            reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text.takeIf { it.length <= 65536 }
        } catch (_: ReaderException) { null }
        finally { reader.reset() }
    }
}
