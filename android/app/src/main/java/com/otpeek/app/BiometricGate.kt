package com.otpeek.app

import android.os.Build
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import javax.crypto.Cipher

class AuthenticationCancelled : Exception()

class BiometricGate(private val activity: FragmentActivity) {
    private val allowed get() = if (Build.VERSION.SDK_INT >= 30)
        BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL
    else BiometricManager.Authenticators.BIOMETRIC_STRONG
    fun available() = BiometricManager.from(activity).canAuthenticate(allowed) == BiometricManager.BIOMETRIC_SUCCESS
    suspend fun authenticate(cipher: Cipher): Cipher = suspendCancellableCoroutine { continuation ->
        if (!available()) {
            continuation.resumeWithException(AuthenticationCancelled())
            return@suspendCancellableCoroutine
        }
        val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    if (continuation.isActive) {
                        val authenticated = result.cryptoObject?.cipher
                        if (authenticated == null) continuation.resumeWithException(AuthenticationCancelled())
                        else continuation.resume(authenticated)
                    }
                }
                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    if (continuation.isActive) continuation.resumeWithException(AuthenticationCancelled())
                }
            })
        val info = BiometricPrompt.PromptInfo.Builder().setTitle(activity.getString(R.string.unlock_title))
            .setAllowedAuthenticators(allowed)
        if (Build.VERSION.SDK_INT < 30) info.setNegativeButtonText(activity.getString(R.string.cancel))
        continuation.invokeOnCancellation { prompt.cancelAuthentication() }
        prompt.authenticate(info.build(), BiometricPrompt.CryptoObject(cipher))
    }
}
