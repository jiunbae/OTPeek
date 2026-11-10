package com.otpeek.app

import android.content.ClipboardManager
import android.content.Context
import android.view.WindowManager
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.text.AnnotatedString
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeFalse
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Run on fresh, disposable fixture emulators only; never overwrite an existing vault. */
class UiFlowTest {
    @get:Rule val rule = createAndroidComposeRule<MainActivity>()
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val root get() = File(context.noBackupFilesDir, "otpeek")
    private var createdFixture = false
    @Before fun freshOnly() { assumeFalse("Existing vault; skip fixture UI flow", File(root, "active").exists()) }
    @After fun cleanup() {
        if (createdFixture) {
            rule.runOnUiThread { ClipboardGuard.get(context).clear() }
            rule.activityRule.scenario.close()
            root.deleteRecursively()
        }
    }
    @Test fun manualHotpCopyAndBackgroundLock() {
        assertTrue(rule.activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0)
        rule.onNodeWithText(context.getString(R.string.master_password)).performScrollTo().performTextInput("fixture-master")
        rule.onNodeWithText(context.getString(R.string.confirm_password)).performScrollTo().performTextInput("fixture-master")
        rule.onNodeWithText(context.getString(R.string.create)).performScrollTo().performClick()
        rule.waitUntil(30000) { File(root, "active").exists() }
        createdFixture = true
        rule.waitUntil(30000) { rule.onAllNodesWithText(context.getString(R.string.add)).fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithText(context.getString(R.string.add)).performClick()
        rule.onNodeWithText(context.getString(R.string.secret)).performTextInput("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        rule.onNodeWithText(context.getString(R.string.account)).performTextInput("RFC fixture")
        rule.onAllNodes(hasScrollToNodeAction()).onLast().performScrollToNode(hasText("HOTP"))
        rule.onNodeWithText("HOTP").performClick()
        rule.onAllNodesWithText(context.getString(R.string.add)).onLast().performClick()
        rule.waitUntil(30000) { rule.onAllNodesWithText(context.getString(R.string.generate)).fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithText(context.getString(R.string.generate)).performScrollTo().performClick()
        rule.waitUntil(30000) { rule.onAllNodesWithText("755224").fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithText(context.getString(R.string.copy)).performScrollTo().performClick()
        rule.runOnUiThread {
            val manager = context.getSystemService(ClipboardManager::class.java)
            assertTrue(manager.primaryClipDescription?.extras?.getBoolean("android.content.extra.IS_SENSITIVE") == true)
        }
        rule.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
        rule.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        rule.runOnUiThread { assertEquals("755224", context.getSystemService(ClipboardManager::class.java).primaryClip?.getItemAt(0)?.text?.toString()) }
        rule.onNodeWithText(context.getString(R.string.unlock_title)).assertIsDisplayed()
        rule.onNodeWithText("755224").assertDoesNotExist()
        rule.onNodeWithText(context.getString(R.string.master_password)).performScrollTo().performTextInput("fixture-master")
        rule.onNodeWithText(context.getString(R.string.unlock)).performScrollTo().performClick()
        rule.waitUntil(30000) { rule.onAllNodesWithText("HOTP · 1").fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithText(context.getString(R.string.generate_first)).performScrollTo().assertIsDisplayed()
        rule.activityRule.scenario.recreate()
        rule.onNodeWithText(context.getString(R.string.unlock_title)).assertIsDisplayed()
        rule.onNodeWithText("755224").assertDoesNotExist()
        rule.onNodeWithText(context.getString(R.string.master_password)).performScrollTo().performTextInput("fixture-master")
        rule.onNodeWithText(context.getString(R.string.unlock)).performScrollTo().performClick()
        rule.waitUntil(30000) { rule.onAllNodesWithText("HOTP · 1").fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithText(context.getString(R.string.generate_first)).performScrollTo().assertIsDisplayed()
    }
    @Test fun draftPasswordIsDiscardedOnRecreation() {
        rule.onNodeWithText(context.getString(R.string.master_password)).performScrollTo().performTextInput("fixture-draft")
        rule.activityRule.scenario.recreate()
        rule.onNodeWithText(context.getString(R.string.master_password))
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString("")))
        assertFalse(File(root, "active").exists())
    }
}
