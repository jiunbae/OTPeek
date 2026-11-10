package com.otpeek.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import android.os.SystemClock
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeFalse
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Only disposable OTPeek AVDs; public codes and separate test-APK clipboard receiver. */
class ClipboardPolicyTest {
    @get:Rule val rule = createAndroidComposeRule<MainActivity>()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private val manager get() = context.getSystemService(ClipboardManager::class.java)
    private val guard get() = ClipboardGuard.get(context)
    private val component get() = ComponentName(instrumentation.context.packageName, ClipboardFixtureActivity::class.java.name)
    private var ready = false
    @Before fun disposableOnly() {
        assumeTrue("Emulator fixtures only", android.os.Build.HARDWARE == "ranchu")
        assumeFalse("Existing vault; refuse fixture flow", File(context.noBackupFilesDir, "otpeek/active").exists())
        rule.waitUntil(10000) { rule.activity.hasWindowFocus() }
        ready = true
    }
    @After fun cleanup() {
        if (!ready) return
        finishReceiver()
        rule.runOnUiThread { guard.clear() }
    }
    private fun row(code: String = "755224", hotp: Boolean = true, lifetime: Long = 30000) =
        AccountRow("public-fixture", "", "RFC fixture", hotp, 0uL, code, System.currentTimeMillis() + lifetime)
    private fun text(): String = manager.primaryClip?.getItemAt(0)?.text?.toString().orEmpty()
    private fun receiver(replace: Boolean = false, expected: String = "755224") {
        val latch = CountDownLatch(1)
        var matches = false
        val reply = object : ResultReceiver(Handler(Looper.getMainLooper())) {
            override fun onReceiveResult(code: Int, data: Bundle) { matches = data.getBoolean("matches"); latch.countDown() }
        }
        context.startActivity(Intent().setComponent(component).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra("reply", reply).putExtra("replace", replace).putExtra("expected", expected))
        assertTrue("Separate receiver did not respond", latch.await(10, TimeUnit.SECONDS))
        assertTrue("Separate app did not see expected public clipboard fixture", matches)
    }
    private fun finishReceiver() {
        context.startActivity(Intent("finish").setComponent(component)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        instrumentation.waitForIdleSync()
        rule.waitUntil(10000) { rule.activity.hasWindowFocus() }
    }
    @Test fun crossAppPasteSurvivesBackgroundAndRotation() {
        rule.runOnUiThread { guard.copy(row()) }
        receiver()
        finishReceiver()
        rule.activityRule.scenario.recreate()
        rule.waitUntil(10000) { rule.activity.hasWindowFocus() }
        rule.runOnUiThread { assertEquals("755224", text()); assertTrue(manager.primaryClipDescription?.extras?.getBoolean("android.content.extra.IS_SENSITIVE") == true) }
    }
    @Test fun totpExpiryClearsOwnedCode() {
        rule.runOnUiThread { guard.copy(row(hotp = false, lifetime = 1000)) }
        SystemClock.sleep(1400)
        rule.runOnUiThread { assertTrue(text().isEmpty()) }
    }
    @Test fun otherAppReplacementSurvivesExpiryAndReturn() {
        rule.runOnUiThread { guard.copy(row(hotp = false, lifetime = 1800)) }
        receiver(replace = true, expected = "public replacement")
        SystemClock.sleep(2200)
        finishReceiver()
        rule.runOnUiThread { assertEquals("public replacement", text()) }
    }
    @Test fun expiredBackgroundCopyIsClearedOnFocusReturn() {
        rule.runOnUiThread { guard.copy(row(hotp = false, lifetime = 1800)) }
        receiver()
        SystemClock.sleep(2200)
        finishReceiver()
        rule.runOnUiThread { assertTrue(text().isEmpty()) }
    }
    @Test fun staleTimerDoesNotClearNewCopy() {
        rule.runOnUiThread { guard.copy(row(hotp = false, lifetime = 500)); guard.copy(row(code = "287082")) }
        SystemClock.sleep(900)
        rule.runOnUiThread { assertEquals("287082", text()) }
    }
    @Test fun invalidCopyDoesNotReplaceOtherContentAndExplicitLockClearsOwn() {
        rule.runOnUiThread {
            manager.setPrimaryClip(ClipData.newPlainText("Public fixture", "public replacement"))
            guard.copy(row(hotp = false, lifetime = -1))
            assertEquals("public replacement", text())
            guard.copy(row())
            guard.clear()
            assertTrue(text().isEmpty())
        }
    }
    @Test fun hotpHasThirtySecondMaximumWhileFocused() {
        rule.runOnUiThread { guard.copy(row()) }
        SystemClock.sleep(1000)
        rule.runOnUiThread { assertEquals("755224", text()) }
        SystemClock.sleep(30000)
        rule.runOnUiThread { assertTrue(text().isEmpty()) }
    }
}
