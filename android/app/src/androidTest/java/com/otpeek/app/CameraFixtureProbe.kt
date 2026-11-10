package com.otpeek.app

import android.Manifest
import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.lifecycle.ProcessCameraProvider
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Explicit emulator-only probe, not part of the ordinary fixture suite or release APK.
 * Run only with the public QR imagefile camera and -e fixture public-rfc.
 */
class CameraFixtureProbe : Instrumentation() {
    private var fixture: String? = null
    override fun onCreate(arguments: Bundle?) { fixture = arguments?.getString("fixture"); start() }
    override fun onStart() {
        val result = Bundle()
        if (Build.HARDWARE != "ranchu" || Build.VERSION.SDK_INT < 28 || fixture != "public-rfc") {
            result.putString("error", "Requires disposable emulator + explicit public fixture")
            finish(Activity.RESULT_CANCELED, result); return
        }
        val executor = Executors.newSingleThreadExecutor()
        var activity: Activity? = null
        var provider: ProcessCameraProvider? = null
        try {
            uiAutomation.grantRuntimePermission(targetContext.packageName, Manifest.permission.CAMERA)
            activity = startActivitySync(Intent(targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            val camera = ProcessCameraProvider.getInstance(targetContext).get(20, TimeUnit.SECONDS)
            provider = camera
            val done = CountDownLatch(1)
            val decoder = QrFrameDecoder()
            var attempts = 0
            val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
            analysis.setAnalyzer(executor) { image ->
                try {
                    attempts++
                    if (done.count == 0L || attempts < 10) return@setAnalyzer
                    val plane = image.planes[0]
                    val decoded = decoder.decode(plane.buffer, image.width, image.height, plane.rowStride, plane.pixelStride)
                    if (decoded != null || attempts >= 60) {
                        result.putBoolean("decodedPublicFixture", decoded?.contains("Camera-fixture") == true)
                        result.putString("layout", "${image.width}x${image.height} row=${plane.rowStride} pixel=${plane.pixelStride} position=${plane.buffer.position()} remaining=${plane.buffer.remaining()}")
                        val pixels = IntArray(image.width * image.height)
                        val start = plane.buffer.position()
                        for (y in 0 until image.height) for (x in 0 until image.width) {
                            val value = plane.buffer.get(start + y * plane.rowStride + x * plane.pixelStride).toInt() and 255
                            pixels[y * image.width + x] = Color.rgb(value, value, value)
                        }
                        val bitmap = Bitmap.createBitmap(pixels, image.width, image.height, Bitmap.Config.ARGB_8888)
                        File(targetContext.cacheDir, "fixture-camera-frame.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                        bitmap.recycle(); done.countDown()
                    }
                } catch (_: Exception) { result.putString("error", "Frame capture failed"); done.countDown() }
                finally { image.close() }
            }
            runOnMainSync { camera.bindToLifecycle(activity as MainActivity, CameraSelector.DEFAULT_BACK_CAMERA, analysis) }
            if (!done.await(30, TimeUnit.SECONDS)) result.putString("error", "No camera frame")
            runOnMainSync { camera.unbind(analysis) }
        } catch (e: Exception) { result.putString("error", e.javaClass.simpleName) }
        finally {
            provider?.let { runOnMainSync { it.unbindAll() } }
            activity?.let { runOnMainSync { it.finish() } }
            executor.shutdown()
        }
        finish(Activity.RESULT_OK, result)
    }
}
