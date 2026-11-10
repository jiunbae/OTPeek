package com.otpeek.app

import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

@Composable
fun QrScanner(modifier: Modifier, onScan: (String) -> Unit, onError: () -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val view = remember { PreviewView(context) }
    AndroidView(factory = { view }, modifier = modifier)
    DisposableEffect(owner) {
        val disposed = AtomicBoolean(false)
        val scanned = AtomicBoolean(false)
        val executor = Executors.newSingleThreadExecutor()
        val future = ProcessCameraProvider.getInstance(context)
        val preview = Preview.Builder().build()
        val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
        val decoder = QrFrameDecoder()
        analysis.setAnalyzer(executor) { image ->
            try {
                if (!disposed.get() && !scanned.get()) {
                    val plane = image.planes[0]
                    val text = decoder.decode(plane.buffer, image.width, image.height, plane.rowStride, plane.pixelStride)
                    if (text != null && scanned.compareAndSet(false, true)) {
                        ContextCompat.getMainExecutor(context).execute { if (!disposed.get()) onScan(text) }
                    }
                }
            } catch (_: Exception) {
                if (scanned.compareAndSet(false, true)) ContextCompat.getMainExecutor(context).execute {
                    if (!disposed.get()) onError()
                }
            } finally { image.close() }
        }
        future.addListener({
            if (!disposed.get()) {
                try {
                    val provider = future.get()
                    preview.setSurfaceProvider(view.surfaceProvider)
                    provider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                } catch (_: Exception) { onError() }
            }
        }, ContextCompat.getMainExecutor(context))
        onDispose {
            disposed.set(true)
            analysis.clearAnalyzer()
            if (future.isDone) runCatching { future.get().unbind(preview, analysis) }
            executor.shutdown()
        }
    }
}
