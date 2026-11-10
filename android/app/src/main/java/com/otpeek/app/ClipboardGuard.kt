package com.otpeek.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.os.SystemClock
import java.util.UUID

class ClipboardGuard private constructor(context: Context) {
    private val manager = context.getSystemService(ClipboardManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private var owner: String? = null
    private var deadline = 0L
    private val expire = Runnable { clearExpired() }
    fun copy(row: AccountRow) {
        val now = System.currentTimeMillis()
        val started = SystemClock.elapsedRealtime()
        if (row.code.isBlank() || (!row.hotp && row.validUntil <= now)) return
        val id = UUID.randomUUID().toString()
        manager.setPrimaryClip(ClipData.newPlainText("OTPeek", row.code).apply {
            description.extras = PersistableBundle().apply {
                putBoolean("android.content.extra.IS_SENSITIVE", true)
                putString("com.otpeek.clip.owner", id)
            }
        })
        owner = id
        val lifetime = if (row.hotp) 30000L else minOf(30000L, row.validUntil - now)
        deadline = started + lifetime
        handler.removeCallbacks(expire)
        handler.postDelayed(expire, maxOf(0L, deadline - SystemClock.elapsedRealtime()))
    }
    fun clearExpired() {
        if (owner != null && SystemClock.elapsedRealtime() >= deadline) clear()
    }
    fun clear() {
        handler.removeCallbacks(expire)
        if (owner == null) return
        // Android can hide clipboard reads while we lack focus. Retain ownership
        // until focus returns; never clear an unverified clip belonging to another app.
        val description = manager.primaryClipDescription ?: return
        if (description.extras?.getString("com.otpeek.clip.owner") == owner) {
            if (android.os.Build.VERSION.SDK_INT >= 28) manager.clearPrimaryClip()
            else manager.setPrimaryClip(ClipData.newPlainText("", ""))
        }
        owner = null
        deadline = 0
    }
    companion object {
        @Volatile private var instance: ClipboardGuard? = null
        fun get(context: Context): ClipboardGuard = instance ?: synchronized(this) {
            instance ?: ClipboardGuard(context.applicationContext).also { instance = it }
        }
    }
}
