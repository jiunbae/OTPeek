//! otpeek-ffi: UniFFI facade exposed to Swift (apple/) and C# (windows/).
//! See docs/ARCHITECTURE.md §7 (frozen contract). Namespace: `otp`.
//!
//! All FFI types are defined here and converted from otpeek-core/otpeek-vault types.
//! This crate is a thin adapter layer: it owns the FFI record/enum definitions,
//! maps Core/Vault/Sync errors onto `OtpError`, and drives `otpeek_vault::Vault` +
//! `otpeek_sync::SyncEngine`. The exported SURFACE is frozen.
#![allow(unused_variables, dead_code)]

use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};

uniffi::setup_scaffolding!("otpeek");

// ---------------------------------------------------------------------------
// Enums / records (mirror docs/ARCHITECTURE.md §3)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum OtpType {
    Totp,
    Hotp,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HashAlgorithm {
    Sha1,
    Sha256,
    Sha512,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct OtpAccount {
    pub id: String,
    pub otp_type: OtpType,
    pub secret: String,
    pub issuer: Option<String>,
    pub account_name: String,
    pub algorithm: HashAlgorithm,
    pub digits: u32,
    pub period: u32,
    pub counter: u64,
    pub folder_id: Option<String>,
    pub is_favorite: bool,
    pub sort_order: i32,
    pub icon: Option<String>,
    pub color: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct OtpFolder {
    pub id: String,
    pub name: String,
    pub icon: Option<String>,
    pub color: Option<String>,
    pub sort_order: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OtpCode {
    pub code: String,
    pub valid_from: i64,
    pub valid_until: i64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AccountCode {
    pub account: OtpAccount,
    pub code: OtpCode,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RemoteBlob {
    pub data: Vec<u8>,
    pub etag: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct SyncOutcome {
    pub pushed: bool,
    pub pulled: bool,
    pub merged_changes: u32,
}

// ---------------------------------------------------------------------------
// Errors — flattened union of Core/Vault/Sync errors
// ---------------------------------------------------------------------------

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum OtpError {
    #[error("invalid secret: {msg}")]
    InvalidSecret { msg: String },
    #[error("invalid uri: {msg}")]
    InvalidUri { msg: String },
    #[error("invalid parameter: {msg}")]
    InvalidParameter { msg: String },
    #[error("wrong password")]
    WrongPassword,
    #[error("wrong key")]
    WrongKey,
    #[error("vault corrupt: {msg}")]
    Corrupt { msg: String },
    #[error("io error: {msg}")]
    Io { msg: String },
    #[error("crypto error: {msg}")]
    Crypto { msg: String },
    #[error("account or folder not found: {id}")]
    NotFound { id: String },
    #[error("sync not configured")]
    NotConfigured,
    #[error("network error: {msg}")]
    Network { msg: String },
    #[error("auth error: {msg}")]
    Auth { msg: String },
    #[error("sync conflict")]
    Conflict,
    #[error("backend error: {msg}")]
    Backend { msg: String },
}

// ---------------------------------------------------------------------------
// Error conversions (Core / Vault / Sync -> OtpError)
// ---------------------------------------------------------------------------

impl From<otpeek_core::CoreError> for OtpError {
    fn from(e: otpeek_core::CoreError) -> Self {
        match e {
            otpeek_core::CoreError::InvalidSecret(msg) => OtpError::InvalidSecret { msg },
            otpeek_core::CoreError::InvalidUri(msg) => OtpError::InvalidUri { msg },
            otpeek_core::CoreError::InvalidParameter(msg) => OtpError::InvalidParameter { msg },
        }
    }
}

impl From<otpeek_vault::VaultError> for OtpError {
    fn from(e: otpeek_vault::VaultError) -> Self {
        match e {
            otpeek_vault::VaultError::WrongPassword => OtpError::WrongPassword,
            otpeek_vault::VaultError::WrongKey => OtpError::WrongKey,
            otpeek_vault::VaultError::Corrupt(msg) => OtpError::Corrupt { msg },
            otpeek_vault::VaultError::Io(msg) => OtpError::Io { msg },
            otpeek_vault::VaultError::Crypto(msg) => OtpError::Crypto { msg },
            otpeek_vault::VaultError::Core(c) => c.into(),
        }
    }
}

impl From<otpeek_sync::SyncError> for OtpError {
    fn from(e: otpeek_sync::SyncError) -> Self {
        match e {
            otpeek_sync::SyncError::NotConfigured => OtpError::NotConfigured,
            otpeek_sync::SyncError::Network(msg) => OtpError::Network { msg },
            otpeek_sync::SyncError::Auth(msg) => OtpError::Auth { msg },
            otpeek_sync::SyncError::Conflict => OtpError::Conflict,
            otpeek_sync::SyncError::Backend(msg) => OtpError::Backend { msg },
            otpeek_sync::SyncError::Vault(v) => v.into(),
        }
    }
}

// ---------------------------------------------------------------------------
// Type conversions (FFI <-> otpeek-core)
// ---------------------------------------------------------------------------

impl From<OtpType> for otpeek_core::OtpType {
    fn from(t: OtpType) -> Self {
        match t {
            OtpType::Totp => otpeek_core::OtpType::Totp,
            OtpType::Hotp => otpeek_core::OtpType::Hotp,
        }
    }
}

impl From<otpeek_core::OtpType> for OtpType {
    fn from(t: otpeek_core::OtpType) -> Self {
        match t {
            otpeek_core::OtpType::Totp => OtpType::Totp,
            otpeek_core::OtpType::Hotp => OtpType::Hotp,
        }
    }
}

impl From<HashAlgorithm> for otpeek_core::HashAlgorithm {
    fn from(a: HashAlgorithm) -> Self {
        match a {
            HashAlgorithm::Sha1 => otpeek_core::HashAlgorithm::Sha1,
            HashAlgorithm::Sha256 => otpeek_core::HashAlgorithm::Sha256,
            HashAlgorithm::Sha512 => otpeek_core::HashAlgorithm::Sha512,
        }
    }
}

impl From<otpeek_core::HashAlgorithm> for HashAlgorithm {
    fn from(a: otpeek_core::HashAlgorithm) -> Self {
        match a {
            otpeek_core::HashAlgorithm::Sha1 => HashAlgorithm::Sha1,
            otpeek_core::HashAlgorithm::Sha256 => HashAlgorithm::Sha256,
            otpeek_core::HashAlgorithm::Sha512 => HashAlgorithm::Sha512,
        }
    }
}

impl From<OtpAccount> for otpeek_core::OtpAccount {
    fn from(a: OtpAccount) -> Self {
        otpeek_core::OtpAccount {
            id: a.id,
            otp_type: a.otp_type.into(),
            secret: a.secret,
            issuer: a.issuer,
            account_name: a.account_name,
            algorithm: a.algorithm.into(),
            digits: a.digits,
            period: a.period,
            counter: a.counter,
            folder_id: a.folder_id,
            is_favorite: a.is_favorite,
            sort_order: a.sort_order,
            icon: a.icon,
            color: a.color,
            created_at: a.created_at,
            updated_at: a.updated_at,
            deleted_at: a.deleted_at,
        }
    }
}

impl From<otpeek_core::OtpAccount> for OtpAccount {
    fn from(a: otpeek_core::OtpAccount) -> Self {
        OtpAccount {
            id: a.id,
            otp_type: a.otp_type.into(),
            secret: a.secret,
            issuer: a.issuer,
            account_name: a.account_name,
            algorithm: a.algorithm.into(),
            digits: a.digits,
            period: a.period,
            counter: a.counter,
            folder_id: a.folder_id,
            is_favorite: a.is_favorite,
            sort_order: a.sort_order,
            icon: a.icon,
            color: a.color,
            created_at: a.created_at,
            updated_at: a.updated_at,
            deleted_at: a.deleted_at,
        }
    }
}

impl From<OtpFolder> for otpeek_core::OtpFolder {
    fn from(f: OtpFolder) -> Self {
        otpeek_core::OtpFolder {
            id: f.id,
            name: f.name,
            icon: f.icon,
            color: f.color,
            sort_order: f.sort_order,
            created_at: f.created_at,
            updated_at: f.updated_at,
            deleted_at: f.deleted_at,
        }
    }
}

impl From<otpeek_core::OtpFolder> for OtpFolder {
    fn from(f: otpeek_core::OtpFolder) -> Self {
        OtpFolder {
            id: f.id,
            name: f.name,
            icon: f.icon,
            color: f.color,
            sort_order: f.sort_order,
            created_at: f.created_at,
            updated_at: f.updated_at,
            deleted_at: f.deleted_at,
        }
    }
}

impl From<otpeek_core::OtpCode> for OtpCode {
    fn from(c: otpeek_core::OtpCode) -> Self {
        OtpCode {
            code: c.code,
            valid_from: c.valid_from,
            valid_until: c.valid_until,
        }
    }
}

// ---------------------------------------------------------------------------
// Time helper: OS wall-clock in Unix epoch milliseconds.
// ---------------------------------------------------------------------------

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Sync backend — foreign-implementable (CloudKit in Swift, etc.)
// ---------------------------------------------------------------------------

#[uniffi::export(with_foreign)]
pub trait SyncBackend: Send + Sync {
    /// `None` = no remote vault exists yet.
    fn fetch(&self) -> Result<Option<RemoteBlob>, OtpError>;
    /// `if_match`: Some(etag) → fail with Conflict if remote changed;
    /// None → create-only. Returns the new etag.
    fn store(&self, data: Vec<u8>, if_match: Option<String>) -> Result<String, OtpError>;
}

/// Adapts a foreign (FFI) `SyncBackend` into the `otpeek_sync::SyncBackend` the
/// engine consumes, translating `OtpError` back into `SyncError`.
struct BackendAdapter {
    inner: Arc<dyn SyncBackend>,
}

fn otp_error_to_sync(e: OtpError) -> otpeek_sync::SyncError {
    match e {
        OtpError::NotConfigured => otpeek_sync::SyncError::NotConfigured,
        OtpError::Network { msg } => otpeek_sync::SyncError::Network(msg),
        OtpError::Auth { msg } => otpeek_sync::SyncError::Auth(msg),
        OtpError::Conflict => otpeek_sync::SyncError::Conflict,
        OtpError::Backend { msg } => otpeek_sync::SyncError::Backend(msg),
        OtpError::WrongKey => otpeek_sync::SyncError::Vault(otpeek_vault::VaultError::WrongKey),
        OtpError::WrongPassword => otpeek_sync::SyncError::Vault(otpeek_vault::VaultError::WrongPassword),
        OtpError::Corrupt { msg } => {
            otpeek_sync::SyncError::Vault(otpeek_vault::VaultError::Corrupt(msg))
        }
        OtpError::Io { msg } => otpeek_sync::SyncError::Vault(otpeek_vault::VaultError::Io(msg)),
        OtpError::Crypto { msg } => otpeek_sync::SyncError::Vault(otpeek_vault::VaultError::Crypto(msg)),
        other => otpeek_sync::SyncError::Backend(other.to_string()),
    }
}

impl otpeek_sync::SyncBackend for BackendAdapter {
    fn fetch(&self) -> Result<Option<otpeek_sync::RemoteBlob>, otpeek_sync::SyncError> {
        match self.inner.fetch().map_err(otp_error_to_sync)? {
            Some(b) => Ok(Some(otpeek_sync::RemoteBlob {
                data: b.data,
                etag: b.etag,
            })),
            None => Ok(None),
        }
    }

    fn store(
        &self,
        data: Vec<u8>,
        if_match: Option<String>,
    ) -> Result<String, otpeek_sync::SyncError> {
        self.inner.store(data, if_match).map_err(otp_error_to_sync)
    }
}

// ---------------------------------------------------------------------------
// OtpClient — the facade. Every mutating call persists atomically to vault_path.
// ---------------------------------------------------------------------------

struct ClientState {
    vault: otpeek_vault::Vault,
    vault_path: String,
    backend: Option<Arc<dyn SyncBackend>>,
}

#[derive(uniffi::Object)]
pub struct OtpClient {
    inner: Mutex<ClientState>,
}

impl OtpClient {
    fn from_vault(vault: otpeek_vault::Vault, vault_path: String) -> Arc<Self> {
        Arc::new(OtpClient {
            inner: Mutex::new(ClientState {
                vault,
                vault_path,
                backend: None,
            }),
        })
    }

    /// Lock the inner state, recovering from a poisoned mutex (no panic).
    fn lock(&self) -> MutexGuard<'_, ClientState> {
        match self.inner.lock() {
            Ok(g) => g,
            Err(p) => p.into_inner(),
        }
    }
}

/// Persist the current vault payload atomically. `now` is the modifiedAt stamp.
fn persist(state: &mut ClientState, now: i64) -> Result<(), OtpError> {
    let bytes = state.vault.to_bytes(now)?;
    otpeek_vault::write_vault_file(Path::new(&state.vault_path), &bytes)?;
    Ok(())
}

#[uniffi::export]
impl OtpClient {
    // --- lifecycle ---

    #[uniffi::constructor]
    pub fn create(vault_path: String, master_password: String) -> Result<Arc<Self>, OtpError> {
        let vault = otpeek_vault::Vault::create(&master_password)?;
        let client = OtpClient::from_vault(vault, vault_path);
        {
            let mut state = client.lock();
            persist(&mut state, now_ms())?;
        }
        Ok(client)
    }

    #[uniffi::constructor]
    pub fn open_with_key(vault_path: String, vmk: Vec<u8>) -> Result<Arc<Self>, OtpError> {
        let data = otpeek_vault::read_vault_file(Path::new(&vault_path))?;
        let vault = otpeek_vault::Vault::open_with_key(&data, &vmk)?;
        Ok(OtpClient::from_vault(vault, vault_path))
    }

    #[uniffi::constructor]
    pub fn open_with_password(
        vault_path: String,
        master_password: String,
    ) -> Result<Arc<Self>, OtpError> {
        let data = otpeek_vault::read_vault_file(Path::new(&vault_path))?;
        let vault = otpeek_vault::Vault::open_with_password(&data, &master_password)?;
        Ok(OtpClient::from_vault(vault, vault_path))
    }

    /// Bootstrap from a remote/backup blob onto this device (writes vault_path).
    #[uniffi::constructor]
    pub fn restore(
        vault_path: String,
        blob: Vec<u8>,
        master_password: String,
    ) -> Result<Arc<Self>, OtpError> {
        let vault = otpeek_vault::Vault::open_with_password(&blob, &master_password)?;
        let client = OtpClient::from_vault(vault, vault_path);
        {
            let mut state = client.lock();
            persist(&mut state, now_ms())?;
        }
        Ok(client)
    }

    /// The raw 32-byte vault master key, for the platform keystore.
    pub fn vault_key(&self) -> Vec<u8> {
        self.lock().vault.vmk()
    }

    /// Re-read the vault file (app ↔ widget coherence).
    pub fn reload(&self) -> Result<(), OtpError> {
        let mut state = self.lock();
        let vmk = state.vault.vmk();
        let data = otpeek_vault::read_vault_file(Path::new(&state.vault_path))?;
        let vault = otpeek_vault::Vault::open_with_key(&data, &vmk)?;
        state.vault = vault;
        Ok(())
    }

    pub fn change_password(&self, old: String, new: String) -> Result<(), OtpError> {
        let mut state = self.lock();
        state.vault.change_password(&old, &new)?;
        persist(&mut state, now_ms())?;
        Ok(())
    }

    // --- accounts (lists exclude tombstones; sorted by sort_order, then issuer) ---

    pub fn list_accounts(&self) -> Vec<OtpAccount> {
        let state = self.lock();
        let mut accounts: Vec<otpeek_core::OtpAccount> = state
            .vault
            .payload()
            .accounts
            .iter()
            .filter(|a| a.deleted_at.is_none())
            .cloned()
            .collect();
        sort_accounts(&mut accounts);
        accounts.into_iter().map(Into::into).collect()
    }

    pub fn get_account(&self, id: String) -> Option<OtpAccount> {
        let state = self.lock();
        state
            .vault
            .payload()
            .accounts
            .iter()
            .find(|a| a.id == id && a.deleted_at.is_none())
            .cloned()
            .map(Into::into)
    }

    /// `account.id` may be "" → assigned. created_at/updated_at always set by core.
    pub fn add_account(&self, account: OtpAccount) -> Result<OtpAccount, OtpError> {
        let now = now_ms();
        let mut core: otpeek_core::OtpAccount = account.into();
        if core.id.trim().is_empty() {
            core.id = uuid::Uuid::new_v4().to_string();
        }
        core.secret = otpeek_core::normalize_secret(&core.secret)?;
        if core.created_at == 0 {
            core.created_at = now;
        }
        core.updated_at = now;

        let mut state = self.lock();
        state.vault.payload_mut().accounts.push(core.clone());
        persist(&mut state, now)?;
        Ok(core.into())
    }

    /// Accepts otpauth:// (1 account) or otpauth-migration:// (many).
    pub fn add_from_uri(&self, uri: String) -> Result<Vec<OtpAccount>, OtpError> {
        let now = now_ms();
        let parsed: Vec<otpeek_core::OtpAccount> = if uri.starts_with("otpauth-migration://") {
            otpeek_core::parse_migration_uri(&uri, now)?
        } else {
            vec![otpeek_core::parse_otpauth_uri(&uri, now)?]
        };

        let mut state = self.lock();
        for a in &parsed {
            state.vault.payload_mut().accounts.push(a.clone());
        }
        persist(&mut state, now)?;
        Ok(parsed.into_iter().map(Into::into).collect())
    }

    pub fn update_account(&self, account: OtpAccount) -> Result<OtpAccount, OtpError> {
        let now = now_ms();
        let mut core: otpeek_core::OtpAccount = account.into();
        core.secret = otpeek_core::normalize_secret(&core.secret)?;

        let mut state = self.lock();
        let existing = state
            .vault
            .payload_mut()
            .accounts
            .iter_mut()
            .find(|a| a.id == core.id && a.deleted_at.is_none());
        let slot = match existing {
            Some(s) => s,
            None => return Err(OtpError::NotFound { id: core.id }),
        };
        if core.created_at == 0 {
            core.created_at = slot.created_at;
        }
        core.updated_at = now;
        *slot = core.clone();
        persist(&mut state, now)?;
        Ok(core.into())
    }

    /// Sets a tombstone (deleted_at = now).
    pub fn delete_account(&self, id: String) -> Result<(), OtpError> {
        let now = now_ms();
        let mut state = self.lock();
        let existing = state
            .vault
            .payload_mut()
            .accounts
            .iter_mut()
            .find(|a| a.id == id && a.deleted_at.is_none());
        match existing {
            Some(a) => {
                a.deleted_at = Some(now);
                a.updated_at = now;
            }
            None => return Err(OtpError::NotFound { id }),
        }
        persist(&mut state, now)?;
        Ok(())
    }

    // --- folders ---

    pub fn list_folders(&self) -> Vec<OtpFolder> {
        let state = self.lock();
        let mut folders: Vec<otpeek_core::OtpFolder> = state
            .vault
            .payload()
            .folders
            .iter()
            .filter(|f| f.deleted_at.is_none())
            .cloned()
            .collect();
        folders.sort_by(|a, b| {
            a.sort_order
                .cmp(&b.sort_order)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });
        folders.into_iter().map(Into::into).collect()
    }

    pub fn add_folder(&self, folder: OtpFolder) -> Result<OtpFolder, OtpError> {
        let now = now_ms();
        let mut core: otpeek_core::OtpFolder = folder.into();
        if core.id.trim().is_empty() {
            core.id = uuid::Uuid::new_v4().to_string();
        }
        if core.created_at == 0 {
            core.created_at = now;
        }
        core.updated_at = now;

        let mut state = self.lock();
        state.vault.payload_mut().folders.push(core.clone());
        persist(&mut state, now)?;
        Ok(core.into())
    }

    pub fn update_folder(&self, folder: OtpFolder) -> Result<OtpFolder, OtpError> {
        let now = now_ms();
        let mut core: otpeek_core::OtpFolder = folder.into();

        let mut state = self.lock();
        let existing = state
            .vault
            .payload_mut()
            .folders
            .iter_mut()
            .find(|f| f.id == core.id && f.deleted_at.is_none());
        let slot = match existing {
            Some(s) => s,
            None => return Err(OtpError::NotFound { id: core.id }),
        };
        if core.created_at == 0 {
            core.created_at = slot.created_at;
        }
        core.updated_at = now;
        *slot = core.clone();
        persist(&mut state, now)?;
        Ok(core.into())
    }

    /// Accounts in the folder survive with folder_id cleared.
    pub fn delete_folder(&self, id: String) -> Result<(), OtpError> {
        let now = now_ms();
        let mut state = self.lock();
        let payload = state.vault.payload_mut();
        let existing = payload
            .folders
            .iter_mut()
            .find(|f| f.id == id && f.deleted_at.is_none());
        match existing {
            Some(f) => {
                f.deleted_at = Some(now);
                f.updated_at = now;
            }
            None => return Err(OtpError::NotFound { id }),
        }
        for a in payload.accounts.iter_mut() {
            if a.folder_id.as_deref() == Some(id.as_str()) {
                a.folder_id = None;
                a.updated_at = now;
            }
        }
        persist(&mut state, now)?;
        Ok(())
    }

    // --- codes ---

    /// Current code for a TOTP account (or HOTP peek without increment).
    pub fn code(&self, id: String, unix_time_ms: i64) -> Result<OtpCode, OtpError> {
        let state = self.lock();
        let account = state
            .vault
            .payload()
            .accounts
            .iter()
            .find(|a| a.id == id && a.deleted_at.is_none());
        let account = match account {
            Some(a) => a,
            None => return Err(OtpError::NotFound { id }),
        };
        let code = otpeek_core::generate_code(account, unix_time_ms)?;
        Ok(code.into())
    }

    /// HOTP: increments the counter and persists, then returns the code.
    pub fn next_hotp(&self, id: String) -> Result<OtpCode, OtpError> {
        let now = now_ms();
        let mut state = self.lock();
        let account = state
            .vault
            .payload_mut()
            .accounts
            .iter_mut()
            .find(|a| a.id == id && a.deleted_at.is_none());
        let account = match account {
            Some(a) => a,
            None => return Err(OtpError::NotFound { id }),
        };
        if account.otp_type != otpeek_core::OtpType::Hotp {
            return Err(OtpError::InvalidParameter {
                msg: "account is not HOTP".to_string(),
            });
        }
        // Code corresponds to the current counter; stored counter becomes +1.
        let code = otpeek_core::generate_code(account, now)?;
        account.counter = account.counter.saturating_add(1);
        account.updated_at = now;
        persist(&mut state, now)?;
        Ok(code.into())
    }

    /// Codes for all (non-deleted) TOTP accounts — for widget timelines.
    pub fn codes_at(&self, unix_time_ms: i64) -> Vec<AccountCode> {
        let state = self.lock();
        let mut accounts: Vec<otpeek_core::OtpAccount> = state
            .vault
            .payload()
            .accounts
            .iter()
            .filter(|a| a.deleted_at.is_none() && a.otp_type == otpeek_core::OtpType::Totp)
            .cloned()
            .collect();
        sort_accounts(&mut accounts);
        accounts
            .into_iter()
            .filter_map(|a| {
                otpeek_core::generate_code(&a, unix_time_ms)
                    .ok()
                    .map(|code| AccountCode {
                        account: a.into(),
                        code: code.into(),
                    })
            })
            .collect()
    }

    // --- backup / sync ---

    /// v2 container encrypted under `password` (independent salt/KEK).
    pub fn export_backup(&self, password: String) -> Result<Vec<u8>, OtpError> {
        let now = now_ms();
        let state = self.lock();
        let payload_clone = state.vault.payload().clone();
        let mut container = otpeek_vault::Vault::create(&password)?;
        *container.payload_mut() = payload_clone;
        let bytes = container.to_bytes(now)?;
        Ok(bytes)
    }

    /// Returns number of imported (non-skipped) entities.
    pub fn import_backup(
        &self,
        data: Vec<u8>,
        password: String,
        merge: bool,
    ) -> Result<u32, OtpError> {
        let imported = otpeek_vault::Vault::open_with_password(&data, &password)?;
        let payload = imported.payload().clone();
        self.apply_import(payload, merge)
    }

    /// Legacy v1 .otpbackup import.
    pub fn import_backup_v1(
        &self,
        data: Vec<u8>,
        password: String,
        merge: bool,
    ) -> Result<u32, OtpError> {
        let now = now_ms();
        let payload = otpeek_vault::import_backup_v1(&data, &password, now)?;
        self.apply_import(payload, merge)
    }

    pub fn set_sync_backend(&self, backend: Arc<dyn SyncBackend>) {
        self.lock().backend = Some(backend);
    }

    pub fn clear_sync_backend(&self) {
        self.lock().backend = None;
    }

    pub fn sync(&self, unix_time_ms: i64) -> Result<SyncOutcome, OtpError> {
        let mut state = self.lock();
        let backend = match state.backend.clone() {
            Some(b) => b,
            None => return Err(OtpError::NotConfigured),
        };
        let adapter = BackendAdapter { inner: backend };
        let outcome = otpeek_sync::SyncEngine::sync(&mut state.vault, &adapter, unix_time_ms)?;
        // Persist the merged local state.
        persist(&mut state, unix_time_ms)?;
        Ok(SyncOutcome {
            pushed: outcome.pushed,
            pulled: outcome.pulled,
            merged_changes: outcome.merged_changes,
        })
    }
}

impl OtpClient {
    /// Shared import merge logic. `merge = false` replaces the payload entirely;
    /// `merge = true` adds unknown ids and resurrects locally-tombstoned
    /// entities that are live in the backup (updated_at is bumped so a later
    /// sync doesn't re-delete them via LWW).
    fn apply_import(&self, payload: otpeek_vault::VaultPayload, merge: bool) -> Result<u32, OtpError> {
        let now = now_ms();
        let mut state = self.lock();
        let count: u32;
        if !merge {
            let total = payload.accounts.len() + payload.folders.len();
            *state.vault.payload_mut() = payload;
            count = total as u32;
        } else {
            let mut imported: u32 = 0;
            let local = state.vault.payload_mut();
            for f in payload.folders {
                if f.deleted_at.is_some() {
                    continue;
                }
                match local.folders.iter().position(|e| e.id == f.id) {
                    Some(i) => {
                        if local.folders[i].deleted_at.is_some() {
                            let mut restored = f;
                            restored.updated_at = now;
                            local.folders[i] = restored;
                            imported += 1;
                        }
                    }
                    None => {
                        local.folders.push(f);
                        imported += 1;
                    }
                }
            }
            for a in payload.accounts {
                if a.deleted_at.is_some() {
                    continue;
                }
                match local.accounts.iter().position(|e| e.id == a.id) {
                    Some(i) => {
                        if local.accounts[i].deleted_at.is_some() {
                            let mut restored = a;
                            restored.updated_at = now;
                            local.accounts[i] = restored;
                            imported += 1;
                        }
                    }
                    None => {
                        local.accounts.push(a);
                        imported += 1;
                    }
                }
            }
            count = imported;
        }
        persist(&mut state, now)?;
        Ok(count)
    }
}

/// Sort accounts by `sort_order`, then issuer (case-insensitive).
fn sort_accounts(accounts: &mut [otpeek_core::OtpAccount]) {
    accounts.sort_by(|a, b| {
        a.sort_order.cmp(&b.sort_order).then_with(|| {
            a.issuer
                .as_deref()
                .unwrap_or("")
                .to_lowercase()
                .cmp(&b.issuer.as_deref().unwrap_or("").to_lowercase())
        })
    });
}

// ---------------------------------------------------------------------------
// Free functions (widget preview, validation UX)
// ---------------------------------------------------------------------------

#[uniffi::export]
pub fn parse_otpauth_uri(uri: String, now_ms: i64) -> Result<OtpAccount, OtpError> {
    let account = otpeek_core::parse_otpauth_uri(&uri, now_ms)?;
    Ok(account.into())
}

#[uniffi::export]
pub fn account_to_uri(account: OtpAccount) -> String {
    let core: otpeek_core::OtpAccount = account.into();
    otpeek_core::to_otpauth_uri(&core)
}

#[uniffi::export]
pub fn validate_secret(secret: String) -> bool {
    otpeek_core::validate_secret(&secret)
}

#[uniffi::export]
pub fn generate_totp_now(
    secret: String,
    algorithm: HashAlgorithm,
    digits: u32,
    period: u32,
    unix_time_secs: i64,
) -> Result<String, OtpError> {
    let code = otpeek_core::generate_totp(&secret, algorithm.into(), digits, period, unix_time_secs)?;
    Ok(code)
}
