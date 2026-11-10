package com.otpeek.app

import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import uniffi.otpeek.HashAlgorithm
import uniffi.otpeek.OtpException
import java.io.ByteArrayOutputStream

data class VaultUiState(
    val session: Long = 0,
    val exists: Boolean = false,
    val unlocked: Boolean = false,
    val biometric: Boolean = false,
    val busy: Boolean = false,
    val rows: List<AccountRow> = emptyList(),
    val message: String? = null,
)

class VaultViewModel(application: Application) : AndroidViewModel(application) {
    internal val repository = VaultRepository(application)
    private val serial = Mutex()
    private val mutable = MutableStateFlow(VaultUiState(exists = repository.exists, biometric = repository.biometricEnabled))
    val state = mutable.asStateFlow()
    @Volatile private var generation = 0L
    private var operation: Job? = null

    init {
        viewModelScope.launch {
            while (isActive) {
                delay(1000)
                val epoch = generation
                if (mutable.value.unlocked && !mutable.value.busy) {
                    withContext(Dispatchers.IO) {
                        serial.withLock {
                            if (epoch == generation && repository.unlocked) {
                                try { publish(epoch, mutable.value.message) } catch (_: Exception) {
                                    repository.lock()
                                    publish(epoch, getApplication<Application>().getString(R.string.operation_failed))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    private fun publish(epoch: Long, message: String? = null) {
        if (epoch != generation) return
        val next = VaultUiState(session = epoch, exists = repository.exists, unlocked = repository.unlocked, biometric = repository.biometricEnabled,
            rows = if (repository.unlocked) repository.rows(System.currentTimeMillis()) else emptyList(), message = message)
        synchronized(this) { if (epoch == generation) mutable.value = next }
    }
    @Synchronized
    fun lock() {
        generation++
        val epoch = generation
        operation?.cancel()
        mutable.value = mutable.value.copy(session = epoch, unlocked = false, busy = false, rows = emptyList(), message = null)
        viewModelScope.launch(Dispatchers.IO) {
            serial.withLock {
                if (epoch == generation && !mutable.value.unlocked) {
                    repository.lock()
                    val exists = repository.exists
                    val biometric = repository.biometricEnabled
                    synchronized(this@VaultViewModel) {
                        if (epoch == generation && !mutable.value.unlocked)
                            mutable.value = mutable.value.copy(exists = exists, biometric = biometric)
                    }
                }
            }
        }
    }
    fun clearMessage() { mutable.value = mutable.value.copy(message = null) }
    private fun run(success: Int? = null, work: suspend () -> Unit) {
        if (mutable.value.busy) return
        val epoch = generation
        mutable.value = mutable.value.copy(busy = true, message = null)
        operation = viewModelScope.launch(Dispatchers.IO) {
            serial.withLock {
                try {
                    ensureActive()
                    work()
                    ensureActive()
                    if (epoch == generation) publish(epoch, success?.let { getApplication<Application>().getString(it) })
                } catch (e: CancellationException) { throw e }
                catch (e: Exception) {
                    if (epoch == generation) {
                        val message = when (e) {
                            is OtpException.WrongPassword -> R.string.wrong_password
                            is OtpException.WrongKey -> R.string.key_unavailable
                            is DeviceKeyUnavailable -> R.string.key_unavailable
                            is AuthenticationCancelled -> R.string.auth_cancelled
                            else -> R.string.operation_failed
                        }
                        publish(epoch, getApplication<Application>().getString(message))
                    }
                } finally {
                    if (epoch != generation) repository.lock()
                }
            }
        }
    }
    fun create(password: String) = run { repository.create(password) }
    fun open(password: String) = run { repository.open(password) }
    fun addManual(secret: String, issuer: String, name: String, hotp: Boolean,
                  algorithm: HashAlgorithm, digits: UInt, period: UInt, counter: ULong) = run {
        repository.addManual(secret, issuer, name, hotp, algorithm, digits, period, counter)
    }
    fun addUri(uri: String) = run(R.string.imported) { repository.addUri(uri) }
    fun next(id: String) = run { repository.nextHotp(id) }
    fun delete(id: String) = run { repository.delete(id) }
    fun enableBiometric(gate: BiometricGate) = run(R.string.biometric_enabled) {
        if (!withContext(Dispatchers.Main) { gate.available() }) throw AuthenticationCancelled()
        val vmk = repository.vaultKey()
        var alias: String? = null
        var saved = false
        try {
            val (newAlias, cipher) = VaultKeyStore.encryption()
            alias = newAlias
            val authenticated = withContext(Dispatchers.Main) { gate.authenticate(cipher) }
            currentCoroutineContext().ensureActive()
            VaultKeyStore.save(repository.wrappingFile(), newAlias, authenticated, vmk)
            saved = true
        } finally {
            vmk.fill(0)
            if (!saved) alias?.let { VaultKeyStore.deleteAlias(it) }
        }
    }
    fun disableBiometric() = run { VaultKeyStore.remove(repository.wrappingFile()) }
    fun openBiometric(gate: BiometricGate) = run {
        val file = repository.wrappingFile()
        val cipher = VaultKeyStore.decryption(file)
        val authenticated = withContext(Dispatchers.Main) { gate.authenticate(cipher) }
        val vmk = VaultKeyStore.unwrap(file, authenticated)
        try { repository.openKey(vmk) } finally { vmk.fill(0) }
    }
    fun export(uri: Uri, master: String, password: String) = run(R.string.exported) {
        repository.open(master)
        currentCoroutineContext().ensureActive()
        val data = repository.export(password)
        try {
            currentCoroutineContext().ensureActive()
            val resolver = getApplication<Application>().contentResolver
            checkNotNull(resolver.openOutputStream(uri, "wt")).use { stream ->
                var offset = 0
                while (offset < data.size) {
                    currentCoroutineContext().ensureActive()
                    val count = minOf(8192, data.size - offset)
                    stream.write(data, offset, count)
                    offset += count
                }
                currentCoroutineContext().ensureActive()
                stream.flush()
            }
        } finally { data.fill(0) }
    }
    fun restore(uri: Uri, password: String, master: String, merge: Boolean, newMaster: String) = run(R.string.restored) {
        val resolver = getApplication<Application>().contentResolver
        val data = checkNotNull(resolver.openInputStream(uri)).use { input ->
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                currentCoroutineContext().ensureActive()
                val count = input.read(buffer)
                if (count < 0) break
                require(out.size().toLong() + count <= BackupGuard.MAX_BYTES)
                out.write(buffer, 0, count)
            }
            out.toByteArray()
        }
        try {
            currentCoroutineContext().ensureActive()
            BackupGuard.check(data)
            if (repository.exists && !repository.unlocked) repository.open(master)
            currentCoroutineContext().ensureActive()
            repository.restore(data, password, merge, newMaster)
        } finally { data.fill(0) }
    }
    override fun onCleared() {
        generation++
        operation?.cancel()
        CoroutineScope(Dispatchers.IO).launch { serial.withLock { repository.lock() } }
    }
}
