package com.otpeek.app

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.fragment.app.FragmentActivity

class MainActivity : FragmentActivity() {
    private val model: VaultViewModel by viewModels()
    private lateinit var clipboard: ClipboardGuard
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        clipboard = ClipboardGuard.get(this)
        val gate = BiometricGate(this)
        setContent { OtpApp(model, gate, clipboard) }
    }
    override fun onStop() {
        model.lock()
        super.onStop()
    }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && ::clipboard.isInitialized) clipboard.clearExpired()
    }
}
