package com.otpeek.app

import android.Manifest
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import uniffi.otpeek.HashAlgorithm

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun OtpApp(model: VaultViewModel, gate: BiometricGate, clipboard: ClipboardGuard) {
    val state by model.state.collectAsStateWithLifecycle()
    var manual by remember { mutableStateOf(false) }
    var scan by remember { mutableStateOf(false) }
    var cameraError by remember { mutableStateOf(false) }
    var deleteId by remember { mutableStateOf<String?>(null) }
    var exportUri by remember { mutableStateOf<Uri?>(null) }
    var importUri by remember { mutableStateOf<Uri?>(null) }
    val exportPicker = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { exportUri = it }
    val importPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { importUri = it }
    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        if (it) scan = true else cameraError = true
    }
    LaunchedEffect(state.unlocked) {
        if (!state.unlocked) { manual = false; scan = false; deleteId = null }
    }
    MaterialTheme(colorScheme = lightColorScheme(primary = Color(0xFF315F4B), surface = Color(0xFFF8FAF7))) {
        Scaffold(topBar = { TopAppBar(title = { Text("OTPeek") }, actions = {
            if (state.unlocked) TextButton(onClick = { model.lock(); clipboard.clear() }) { Text(stringResource(R.string.lock)) }
        }) }) { padding ->
            Column(Modifier.padding(padding).padding(horizontal = 20.dp).fillMaxSize().imePadding()) {
                if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                state.message?.let { message ->
                    Text(message, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(vertical = 12.dp))
                }
                if (!state.unlocked) {
                    key(state.session) { UnlockPanel(state, model, gate, Modifier.weight(1f)) }
                    TextButton(onClick = { importPicker.launch(arrayOf("*/*")) }, enabled = !state.busy) {
                        Text(stringResource(R.string.restore))
                    }
                } else {
                    Text(stringResource(R.string.clipboard_notice), style = MaterialTheme.typography.bodySmall)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(onClick = { manual = true }, enabled = !state.busy) { Text(stringResource(R.string.add)) }
                        OutlinedButton(onClick = { cameraPermission.launch(Manifest.permission.CAMERA) }, enabled = !state.busy) {
                            Text(stringResource(R.string.scan))
                        }
                    }
                    LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(vertical = 16.dp)) {
                        if (state.rows.isEmpty()) item { Text(stringResource(R.string.empty)) }
                        items(state.rows, key = { it.id }) { row ->
                            Card(Modifier.fillMaxWidth()) {
                                Column(Modifier.padding(16.dp)) {
                                    Text(row.issuer.ifBlank { row.name }.ifBlank { stringResource(R.string.unnamed) }, style = MaterialTheme.typography.titleMedium)
                                    if (row.issuer.isNotBlank()) Text(row.name, style = MaterialTheme.typography.bodyMedium)
                                    Text(row.code.ifBlank { stringResource(R.string.generate_first) }, fontFamily = FontFamily.Monospace,
                                        style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(vertical = 8.dp))
                                    Text(if (row.hotp) "HOTP · ${row.counter}" else
                                        stringResource(R.string.expires, maxOf(0, (row.validUntil - System.currentTimeMillis() + 999) / 1000)),
                                        style = MaterialTheme.typography.bodySmall)
                                    FlowRow {
                                        if (row.hotp) TextButton(onClick = { model.next(row.id) }, enabled = !state.busy && row.counter != ULong.MAX_VALUE) {
                                            Text(stringResource(R.string.generate))
                                        }
                                        TextButton(onClick = { clipboard.copy(row) }, enabled = !state.busy && row.code.isNotBlank()) { Text(stringResource(R.string.copy)) }
                                        TextButton(onClick = { deleteId = row.id }, enabled = !state.busy) { Text(stringResource(R.string.delete)) }
                                    }
                                }
                            }
                        }
                    }
                    FlowRow {
                        TextButton(onClick = { exportPicker.launch("otpeek-backup.otpvault") }, enabled = !state.busy) { Text(stringResource(R.string.backup)) }
                        TextButton(onClick = { importPicker.launch(arrayOf("*/*")) }, enabled = !state.busy) { Text(stringResource(R.string.restore)) }
                    }
                    TextButton(onClick = { if (state.biometric) model.disableBiometric() else model.enableBiometric(gate) }, enabled = !state.busy) {
                        Text(stringResource(if (state.biometric) R.string.disable_biometric else R.string.enable_biometric))
                    }
                }
            }
        }
        if (manual) ManualDialog(onDismiss = { manual = false }) { secret, issuer, name, hotp, algorithm, digits, period, counter ->
            manual = false
            model.addManual(secret, issuer, name, hotp, algorithm, digits, period, counter)
        }
        if (scan) Dialog(onDismissRequest = { scan = false }) {
            Surface(shape = MaterialTheme.shapes.large) { Column(Modifier.padding(16.dp)) {
                Text(stringResource(R.string.scan_notice))
                QrScanner(Modifier.fillMaxWidth().height(320.dp), onScan = { scan = false; model.addUri(it) }, onError = { scan = false; cameraError = true })
                TextButton(onClick = { scan = false }) { Text(stringResource(R.string.cancel)) }
            } }
        }
        if (cameraError) AlertDialog(onDismissRequest = { cameraError = false }, title = { Text(stringResource(R.string.scan)) },
            text = { Text(stringResource(R.string.camera_denied)) }, confirmButton = { TextButton(onClick = { cameraError = false }) { Text(stringResource(R.string.ok)) } })
        deleteId?.let { id -> AlertDialog(onDismissRequest = { deleteId = null }, title = { Text(stringResource(R.string.delete)) },
            text = { Text(stringResource(R.string.delete_notice)) }, confirmButton = { TextButton(onClick = { deleteId = null; model.delete(id) }) { Text(stringResource(R.string.delete)) } },
            dismissButton = { TextButton(onClick = { deleteId = null }) { Text(stringResource(R.string.cancel)) } }) }
        exportUri?.let { uri -> key(state.session) { BackupDialog(export = true, exists = state.exists, onDismiss = { exportUri = null }) { password, master, _, _ ->
            exportUri = null; model.export(uri, master, password)
        } } }
        importUri?.let { uri -> key(state.session) { BackupDialog(export = false, exists = state.exists, onDismiss = { importUri = null }) { password, master, merge, newMaster ->
            importUri = null; model.restore(uri, password, master, merge, newMaster)
        } } }
    }
}

@Composable
private fun UnlockPanel(state: VaultUiState, model: VaultViewModel, gate: BiometricGate, modifier: Modifier) {
    var password by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    Column(modifier.verticalScroll(rememberScrollState()).padding(top = 32.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(stringResource(if (state.exists) R.string.unlock_title else R.string.create_title), style = MaterialTheme.typography.headlineSmall)
        Text(stringResource(R.string.storage_notice))
        PasswordField(password, { password = it }, R.string.master_password)
        if (!state.exists) PasswordField(confirm, { confirm = it }, R.string.confirm_password)
        Button(onClick = {
            val submitted = password
            password = ""; confirm = ""
            if (state.exists) model.open(submitted) else model.create(submitted)
        }, enabled = !state.busy && if (state.exists) password.isNotEmpty() else password.length >= 10 && password == confirm) {
            Text(stringResource(if (state.exists) R.string.unlock else R.string.create))
        }
        if (state.exists && state.biometric) OutlinedButton(onClick = { model.openBiometric(gate) }, enabled = !state.busy) {
            Text(stringResource(R.string.device_unlock))
        }
    }
}

@Composable
private fun PasswordField(value: String, onValue: (String) -> Unit, label: Int) {
    OutlinedTextField(value, onValue, label = { Text(stringResource(label)) }, modifier = Modifier.fillMaxWidth(), singleLine = true,
        visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ManualDialog(onDismiss: () -> Unit, onAdd: (String, String, String, Boolean, HashAlgorithm, UInt, UInt, ULong) -> Unit) {
    var secret by remember { mutableStateOf("") }
    var issuer by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var hotp by remember { mutableStateOf(false) }
    var algorithm by remember { mutableStateOf(HashAlgorithm.SHA1) }
    var digits by remember { mutableStateOf("6") }
    var period by remember { mutableStateOf("30") }
    var counter by remember { mutableStateOf("0") }
    val valid = name.isNotBlank() && secret.isNotBlank() && digits.toUIntOrNull()?.let { it in 6u..8u } == true &&
        period.toUIntOrNull()?.let { it > 0u } == true && counter.toULongOrNull() != null
    AlertDialog(onDismissRequest = onDismiss, title = { Text(stringResource(R.string.add)) }, text = {
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            item { PasswordField(secret, { secret = it }, R.string.secret) }
            item { OutlinedTextField(name, { name = it }, label = { Text(stringResource(R.string.account)) }, singleLine = true) }
            item { OutlinedTextField(issuer, { issuer = it }, label = { Text(stringResource(R.string.issuer)) }, singleLine = true) }
            item { Row { FilterChip(!hotp, { hotp = false }, label = { Text("TOTP") }); Spacer(Modifier.width(8.dp)); FilterChip(hotp, { hotp = true }, label = { Text("HOTP") }) } }
            item { FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) { HashAlgorithm.entries.forEach { a -> FilterChip(algorithm == a, { algorithm = a }, label = { Text(a.name) }) } } }
            item { OutlinedTextField(digits, { digits = it }, label = { Text(stringResource(R.string.digits)) }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number)) }
            item { if (hotp) OutlinedTextField(counter, { counter = it }, label = { Text(stringResource(R.string.counter)) }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                else OutlinedTextField(period, { period = it }, label = { Text(stringResource(R.string.period)) }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number)) }
        }
    }, confirmButton = { TextButton(onClick = { onAdd(secret, issuer, name, hotp, algorithm, digits.toUInt(), period.toUInt(), counter.toULong()) }, enabled = valid) {
        Text(stringResource(R.string.add))
    } }, dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } })
}

@Composable
private fun BackupDialog(export: Boolean, exists: Boolean, onDismiss: () -> Unit,
                         onSubmit: (String, String, Boolean, String) -> Unit) {
    var password by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    var master by remember { mutableStateOf("") }
    var newMaster by remember { mutableStateOf("") }
    var merge by remember { mutableStateOf(true) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text(stringResource(if (export) R.string.backup else R.string.restore)) }, text = {
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            item { Text(stringResource(if (export) R.string.backup_notice else R.string.restore_notice)) }
            if (exists) item { PasswordField(master, { master = it }, R.string.master_password) }
            item { PasswordField(password, { password = it }, R.string.backup_password) }
            if (export) item { PasswordField(confirm, { confirm = it }, R.string.confirm_password) }
            if (!export && !exists) item { PasswordField(newMaster, { newMaster = it }, R.string.legacy_master) }
            if (!export && exists) item {
                Row { Checkbox(merge, { merge = it }); Text(stringResource(R.string.merge)) }
                if (!merge) Text(stringResource(R.string.replace_warning), color = MaterialTheme.colorScheme.error)
            }
        }
    }, confirmButton = { TextButton(onClick = { onSubmit(password, master, merge, newMaster) },
        enabled = password.isNotEmpty() && (!exists || master.isNotEmpty()) && (!export || password.length >= 10 && password == confirm)) {
        Text(stringResource(if (export) R.string.backup else R.string.restore))
    } }, dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } })
}
