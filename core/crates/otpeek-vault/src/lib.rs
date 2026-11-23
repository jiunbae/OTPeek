//! otpeek-vault: vault container v2 (Argon2id-wrapped VMK + AES-256-GCM payload),
//! atomic file I/O, legacy .otpbackup v1 import.
//! See docs/ARCHITECTURE.md §5 (frozen contract).

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use argon2::{Algorithm, Argon2, Params, Version};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use otpeek_core::{CoreError, HashAlgorithm, OtpAccount, OtpFolder, OtpType};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::borrow::Cow;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::Path;
use thiserror::Error;
use zeroize::{Zeroize, Zeroizing};

#[derive(Debug, Error)]
pub enum VaultError {
    #[error("wrong password")]
    WrongPassword,
    #[error("wrong key")]
    WrongKey,
    #[error("vault corrupt: {0}")]
    Corrupt(String),
    #[error("io error: {0}")]
    Io(String),
    #[error("vault file changed; reload or reopen it, then retry")]
    StaleFile,
    #[error("crypto error: {0}")]
    Crypto(String),
    #[error(transparent)]
    Core(#[from] CoreError),
}

#[derive(Debug, Clone, Default, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VaultPayload {
    #[serde(default)]
    pub accounts: Vec<OtpAccount>,
    #[serde(default)]
    pub folders: Vec<OtpFolder>,
}

impl VaultPayload {
    /// Keep the data needed to merge a deletion while dropping deleted secrets
    /// and metadata. The serialized records still use the v2 account and folder types.
    pub fn compact_tombstones(&mut self) {
        for account in self.accounts.iter_mut().filter(|a| a.deleted_at.is_some()) {
            *account = compact_account(account);
        }
        for folder in self.folders.iter_mut().filter(|f| f.deleted_at.is_some()) {
            *folder = compact_folder(folder);
        }
    }
}

fn compact_account(account: &OtpAccount) -> OtpAccount {
    OtpAccount {
        id: account.id.clone(),
        otp_type: OtpType::Totp,
        secret: String::new(),
        issuer: None,
        account_name: String::new(),
        algorithm: HashAlgorithm::Sha1,
        digits: 6,
        period: 30,
        counter: account.counter,
        folder_id: None,
        is_favorite: false,
        sort_order: 0,
        icon: None,
        color: None,
        created_at: account.created_at,
        updated_at: account.updated_at,
        deleted_at: account.deleted_at,
    }
}

fn compact_folder(folder: &OtpFolder) -> OtpFolder {
    OtpFolder {
        id: folder.id.clone(),
        name: String::new(),
        icon: None,
        color: None,
        sort_order: 0,
        created_at: folder.created_at,
        updated_at: folder.updated_at,
        deleted_at: folder.deleted_at,
    }
}

// ---------------------------------------------------------------------------
// Constants / format
// ---------------------------------------------------------------------------

const MAGIC: &[u8; 8] = b"OTPVAULT";
const FORMAT_VERSION: u32 = 2;
const PAYLOAD_VERSION: u32 = 2;
const VMK_LEN: usize = 32;
const SALT_LEN: usize = 32;
const NONCE_LEN: usize = 12;
const TAG_LEN: usize = 16;
const WRAPPED_CT_LEN: usize = VMK_LEN + TAG_LEN; // 48
pub const MAX_VAULT_BYTES: usize = 16 * 1024 * 1024;
const MAX_HEADER_BYTES: usize = 4 * 1024;

// Argon2id params (frozen §5.1).
const ARGON2_M_KIB: u32 = 65536;
const ARGON2_T: u32 = 3;
const ARGON2_P: u32 = 1;

// ---------------------------------------------------------------------------
// Header (on-disk JSON)
// ---------------------------------------------------------------------------

#[derive(Serialize, Deserialize)]
struct KdfJson {
    algo: String,
    #[serde(rename = "mKib")]
    m_kib: u32,
    t: u32,
    p: u32,
    salt: String,
}

#[derive(Serialize, Deserialize)]
struct WrappedVmkJson {
    nonce: String,
    ct: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HeaderJson {
    kdf: KdfJson,
    wrapped_vmk: WrappedVmkJson,
    vault_nonce: String,
    modified_at: i64,
    generation: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    password_revision: Option<u64>,
}

// Encrypted payload wire representation (adds `version`).
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PayloadWireRef<'a> {
    version: u32,
    accounts: Vec<Cow<'a, OtpAccount>>,
    folders: Vec<Cow<'a, OtpFolder>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PayloadWireOwned {
    #[serde(default)]
    accounts: Vec<OtpAccount>,
    #[serde(default)]
    folders: Vec<OtpFolder>,
}

// ---------------------------------------------------------------------------
// Vault
// ---------------------------------------------------------------------------

/// Decrypted, in-memory vault. Not `Sync` by contract — callers wrap in a Mutex.
#[derive(Clone)]
pub struct Vault {
    payload: VaultPayload,
    vmk: Vec<u8>,
    generation: u64,
    file_revision: Option<[u8; 32]>,
    password_revision: Option<u64>,
    // KDF salt + wrapped VMK are preserved across saves so key-path opens can
    // re-serialize the header without knowing the password.
    password_wrap: PasswordWrap,
}

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
struct PasswordWrap {
    salt: Vec<u8>,
    nonce: Vec<u8>,
    ct: Vec<u8>,
}

impl Drop for Vault {
    fn drop(&mut self) {
        self.vmk.zeroize();
    }
}

fn os_random(buf: &mut [u8]) {
    rand::rngs::OsRng.fill_bytes(buf);
}

fn argon2_kek(password: &str, salt: &[u8]) -> Result<[u8; 32], VaultError> {
    let params = Params::new(ARGON2_M_KIB, ARGON2_T, ARGON2_P, Some(VMK_LEN))
        .map_err(|e| VaultError::Crypto(format!("argon2 params: {e}")))?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut out = [0u8; 32];
    argon2
        .hash_password_into(password.as_bytes(), salt, &mut out)
        .map_err(|e| VaultError::Crypto(format!("argon2: {e}")))?;
    Ok(out)
}

fn cipher_from(key: &[u8]) -> Result<Aes256Gcm, VaultError> {
    Aes256Gcm::new_from_slice(key).map_err(|e| VaultError::Crypto(format!("aes key: {e}")))
}

impl Vault {
    /// Create a fresh vault: random VMK, KEK = Argon2id(master_password).
    pub fn create(master_password: &str) -> Result<Vault, VaultError> {
        let mut vmk = vec![0u8; VMK_LEN];
        os_random(&mut vmk);
        let mut salt = vec![0u8; SALT_LEN];
        os_random(&mut salt);
        let mut wrapped_nonce = vec![0u8; NONCE_LEN];
        os_random(&mut wrapped_nonce);

        let mut kek = argon2_kek(master_password, &salt)?;
        let wrap_result = cipher_from(&kek).and_then(|c| {
            c.encrypt(Nonce::from_slice(&wrapped_nonce), vmk.as_slice())
                .map_err(|e| VaultError::Crypto(format!("wrap vmk: {e}")))
        });
        kek.zeroize();
        let wrapped_ct = wrap_result?;

        Ok(Vault {
            payload: VaultPayload::default(),
            vmk,
            generation: 0,
            file_revision: None,
            password_revision: None,
            password_wrap: PasswordWrap {
                salt,
                nonce: wrapped_nonce,
                ct: wrapped_ct,
            },
        })
    }

    /// The raw 32-byte vault master key (for platform keystores).
    pub fn vmk(&self) -> Vec<u8> {
        self.vmk.clone()
    }

    pub fn open_with_key(data: &[u8], vmk: &[u8]) -> Result<Vault, VaultError> {
        let parsed = ParsedFile::parse(data)?;
        if vmk.len() != VMK_LEN {
            return Err(VaultError::WrongKey);
        }
        let payload = parsed.decrypt_payload(vmk).map_err(|e| match e {
            VaultError::Crypto(_) => VaultError::WrongKey,
            other => other,
        })?;
        Ok(parsed.into_vault(vmk.to_vec(), payload))
    }

    /// Open another encrypted copy of this vault using its existing VMK.
    pub fn open_peer(&self, data: &[u8]) -> Result<Vault, VaultError> {
        Self::open_with_key(data, &self.vmk)
    }

    pub fn open_with_password(data: &[u8], master_password: &str) -> Result<Vault, VaultError> {
        let parsed = ParsedFile::parse(data)?;
        // Unwrap VMK with the password-derived KEK.
        let mut kek = argon2_kek(master_password, &parsed.password_wrap.salt)?;
        let unwrap = cipher_from(&kek).and_then(|c| {
            c.decrypt(
                Nonce::from_slice(&parsed.password_wrap.nonce),
                parsed.password_wrap.ct.as_slice(),
            )
            .map_err(|e| VaultError::Crypto(format!("unwrap vmk: {e}")))
        });
        kek.zeroize();
        let vmk = unwrap.map_err(|_| VaultError::WrongPassword)?;
        if vmk.len() != VMK_LEN {
            return Err(VaultError::WrongPassword);
        }
        // Payload auth failure on the password path also maps to WrongPassword.
        let payload = parsed.decrypt_payload(&vmk).map_err(|e| match e {
            VaultError::Crypto(_) => VaultError::WrongPassword,
            other => other,
        })?;
        Ok(parsed.into_vault(vmk, payload))
    }

    /// Serialize with a fresh nonce and increment the generation on success.
    /// Keep tombstones so a device returning after a long gap cannot resurrect them.
    pub fn to_bytes(&mut self, now_ms: i64) -> Result<Vec<u8>, VaultError> {
        let (generation, data) = self.serialize(now_ms)?;
        self.payload.compact_tombstones();
        self.generation = generation;
        Ok(data)
    }

    fn serialize(&self, now_ms: i64) -> Result<(u64, Vec<u8>), VaultError> {
        let generation = self
            .generation
            .checked_add(1)
            .ok_or_else(|| VaultError::Corrupt("vault generation exhausted".into()))?;
        let mut vault_nonce = vec![0u8; NONCE_LEN];
        os_random(&mut vault_nonce);

        let header = HeaderJson {
            kdf: KdfJson {
                algo: "argon2id".to_string(),
                m_kib: ARGON2_M_KIB,
                t: ARGON2_T,
                p: ARGON2_P,
                salt: B64.encode(&self.password_wrap.salt),
            },
            wrapped_vmk: WrappedVmkJson {
                nonce: B64.encode(&self.password_wrap.nonce),
                ct: B64.encode(&self.password_wrap.ct),
            },
            vault_nonce: B64.encode(&vault_nonce),
            modified_at: now_ms,
            generation,
            password_revision: self.password_revision,
        };
        let header_bytes = serde_json::to_vec(&header)
            .map_err(|e| VaultError::Crypto(format!("header encode: {e}")))?;

        let payload = PayloadWireRef {
            version: PAYLOAD_VERSION,
            accounts: self
                .payload
                .accounts
                .iter()
                .map(|account| {
                    if account.deleted_at.is_some() {
                        Cow::Owned(compact_account(account))
                    } else {
                        Cow::Borrowed(account)
                    }
                })
                .collect(),
            folders: self
                .payload
                .folders
                .iter()
                .map(|folder| {
                    if folder.deleted_at.is_some() {
                        Cow::Owned(compact_folder(folder))
                    } else {
                        Cow::Borrowed(folder)
                    }
                })
                .collect(),
        };
        let payload_json = Zeroizing::new(
            serde_json::to_vec(&payload)
                .map_err(|e| VaultError::Crypto(format!("payload encode: {e}")))?,
        );
        ensure_size(16 + header_bytes.len() + payload_json.len() + TAG_LEN)?;

        // AAD = magic || version || header length || header bytes (the whole prefix).
        let mut prefix = Vec::with_capacity(16 + header_bytes.len());
        prefix.extend_from_slice(MAGIC);
        prefix.extend_from_slice(&FORMAT_VERSION.to_le_bytes());
        prefix.extend_from_slice(&(header_bytes.len() as u32).to_le_bytes());
        prefix.extend_from_slice(&header_bytes);

        let cipher = cipher_from(&self.vmk)?;
        let ct = cipher
            .encrypt(
                Nonce::from_slice(&vault_nonce),
                Payload {
                    msg: &payload_json,
                    aad: &prefix,
                },
            )
            .map_err(|e| VaultError::Crypto(format!("encrypt payload: {e}")))?;

        let mut out = prefix;
        out.extend_from_slice(&ct);
        Ok((generation, out))
    }

    /// Commit only if the destination still matches the file this vault was
    /// opened from or last saved to. For a new vault, the destination must be absent.
    pub fn save_to_file(&mut self, path: &Path, now_ms: i64) -> Result<(), VaultError> {
        self.save_file(path, now_ms, FileWrite::Compare(self.file_revision))
    }

    /// Check a snapshot before starting external work. The eventual save still
    /// compares under lock, since the file can change after this check.
    pub fn check_file_revision(&self, path: &Path) -> Result<(), VaultError> {
        check_file_revision(path, self.file_revision)
    }

    /// Explicitly replace an existing local file with an authenticated restore.
    pub fn restore_to_file(&mut self, path: &Path, now_ms: i64) -> Result<(), VaultError> {
        self.save_file(path, now_ms, FileWrite::Replace)
    }

    /// Restore an authenticated snapshot into a destination that must be absent.
    pub fn restore_to_new_file(&mut self, path: &Path, now_ms: i64) -> Result<(), VaultError> {
        self.save_file(path, now_ms, FileWrite::Compare(None))
    }

    fn save_file(&mut self, path: &Path, now_ms: i64, mode: FileWrite) -> Result<(), VaultError> {
        let (generation, data) = self.serialize(now_ms)?;
        commit_vault_file(path, &data, mode)?;
        self.payload.compact_tombstones();
        self.file_revision = Some(Sha256::digest(&data).into());
        self.generation = generation;
        Ok(())
    }

    /// Re-wrap the VMK under a new password-derived KEK (no payload re-encryption).
    pub fn change_password(&mut self, old: &str, new: &str) -> Result<(), VaultError> {
        // Verify the old password by unwrapping the stored VMK.
        let next_revision = self
            .password_revision
            .unwrap_or(0)
            .checked_add(1)
            .ok_or_else(|| VaultError::Corrupt("password revision exhausted".into()))?;
        let mut old_kek = argon2_kek(old, &self.password_wrap.salt)?;
        let check = cipher_from(&old_kek).and_then(|c| {
            c.decrypt(
                Nonce::from_slice(&self.password_wrap.nonce),
                self.password_wrap.ct.as_slice(),
            )
            .map_err(|e| VaultError::Crypto(format!("unwrap vmk: {e}")))
        });
        old_kek.zeroize();
        let mut recovered = check.map_err(|_| VaultError::WrongPassword)?;
        let matches = recovered == self.vmk;
        recovered.zeroize();
        if !matches {
            return Err(VaultError::WrongPassword);
        }

        // Fresh salt + nonce, re-wrap with the new KEK. Payload untouched.
        let mut new_salt = vec![0u8; SALT_LEN];
        os_random(&mut new_salt);
        let mut new_nonce = vec![0u8; NONCE_LEN];
        os_random(&mut new_nonce);
        let mut new_kek = argon2_kek(new, &new_salt)?;
        let wrap = cipher_from(&new_kek).and_then(|c| {
            c.encrypt(Nonce::from_slice(&new_nonce), self.vmk.as_slice())
                .map_err(|e| VaultError::Crypto(format!("rewrap vmk: {e}")))
        });
        new_kek.zeroize();
        let new_ct = wrap?;

        self.password_wrap = PasswordWrap {
            salt: new_salt,
            nonce: new_nonce,
            ct: new_ct,
        };
        self.password_revision = Some(next_revision);
        Ok(())
    }

    /// Reconcile authenticated password wraps for two copies of the same vault.
    /// The password revision advances only on rewraps, independent of regular saves.
    /// Keep the local wrap when both copies predate revisions. Their timestamps
    /// track regular saves as well, so they cannot identify the newer password.
    pub fn merge_password_wrap(&mut self, remote: &Vault) -> Result<bool, VaultError> {
        if self.vmk != remote.vmk {
            return Err(VaultError::WrongKey);
        }

        let local_wrap = (&self.password_revision, &self.password_wrap);
        let remote_wrap = (&remote.password_revision, &remote.password_wrap);
        if remote.password_revision.is_none() || remote_wrap <= local_wrap {
            return Ok(false);
        }
        self.password_wrap = remote.password_wrap.clone();
        self.password_revision = remote.password_revision;
        Ok(true)
    }

    pub fn payload(&self) -> &VaultPayload {
        &self.payload
    }

    pub fn payload_mut(&mut self) -> &mut VaultPayload {
        &mut self.payload
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }
}

// ---------------------------------------------------------------------------
// Parsed on-disk file (shared by both open paths)
// ---------------------------------------------------------------------------

struct ParsedFile<'a> {
    password_wrap: PasswordWrap,
    vault_nonce: Vec<u8>,
    generation: u64,
    password_revision: Option<u64>,
    data: &'a [u8],
    header_end: usize,
}

fn ensure_size(len: usize) -> Result<(), VaultError> {
    if len > MAX_VAULT_BYTES {
        return Err(VaultError::Corrupt("vault exceeds the size limit".into()));
    }
    Ok(())
}

fn b64_fixed(s: &str, expected: usize, what: &str) -> Result<Vec<u8>, VaultError> {
    let bytes = B64
        .decode(s)
        .map_err(|e| VaultError::Corrupt(format!("{what} base64: {e}")))?;
    if bytes.len() != expected {
        return Err(VaultError::Corrupt(format!(
            "{what} length {} != {expected}",
            bytes.len()
        )));
    }
    Ok(bytes)
}

impl<'a> ParsedFile<'a> {
    fn parse(data: &'a [u8]) -> Result<Self, VaultError> {
        ensure_size(data.len())?;
        if data.len() < 16 {
            return Err(VaultError::Corrupt("file too short".into()));
        }
        if &data[0..8] != MAGIC.as_slice() {
            return Err(VaultError::Corrupt("bad magic".into()));
        }
        let version = u32::from_le_bytes([data[8], data[9], data[10], data[11]]);
        if version != FORMAT_VERSION {
            return Err(VaultError::Corrupt(format!(
                "unsupported version {version}"
            )));
        }
        let header_len = u32::from_le_bytes([data[12], data[13], data[14], data[15]]) as usize;
        if header_len > MAX_HEADER_BYTES {
            return Err(VaultError::Corrupt("header exceeds the size limit".into()));
        }
        let header_end = 16 + header_len;
        if header_end + TAG_LEN > data.len() {
            return Err(VaultError::Corrupt("truncated header or payload".into()));
        }
        let header_bytes = &data[16..header_end];
        let header: HeaderJson = serde_json::from_slice(header_bytes)
            .map_err(|e| VaultError::Corrupt(format!("header json: {e}")))?;

        if header.kdf.algo != "argon2id"
            || (header.kdf.m_kib, header.kdf.t, header.kdf.p) != (ARGON2_M_KIB, ARGON2_T, ARGON2_P)
        {
            return Err(VaultError::Corrupt("unsupported v2 KDF parameters".into()));
        }
        let password_wrap = PasswordWrap {
            salt: b64_fixed(&header.kdf.salt, SALT_LEN, "salt")?,
            nonce: b64_fixed(&header.wrapped_vmk.nonce, NONCE_LEN, "wrapped nonce")?,
            ct: b64_fixed(&header.wrapped_vmk.ct, WRAPPED_CT_LEN, "wrapped ct")?,
        };
        let vault_nonce = b64_fixed(&header.vault_nonce, NONCE_LEN, "vault nonce")?;

        Ok(ParsedFile {
            password_wrap,
            vault_nonce,
            generation: header.generation,
            password_revision: header.password_revision,
            data,
            header_end,
        })
    }

    /// Decrypt the payload with a raw VMK. GCM auth failure → `Crypto` (callers
    /// remap to WrongKey/WrongPassword); JSON failure → `Corrupt`.
    fn decrypt_payload(&self, vmk: &[u8]) -> Result<VaultPayload, VaultError> {
        let cipher = cipher_from(vmk)?;
        let plaintext = Zeroizing::new(
            cipher
                .decrypt(
                    Nonce::from_slice(&self.vault_nonce),
                    Payload {
                        msg: &self.data[self.header_end..],
                        aad: &self.data[..self.header_end],
                    },
                )
                .map_err(|e| VaultError::Crypto(format!("decrypt payload: {e}")))?,
        );
        let wire: PayloadWireOwned = serde_json::from_slice(&plaintext)
            .map_err(|e| VaultError::Corrupt(format!("payload json: {e}")))?;
        Ok(VaultPayload {
            accounts: wire.accounts,
            folders: wire.folders,
        })
    }

    fn into_vault(self, vmk: Vec<u8>, mut payload: VaultPayload) -> Vault {
        payload.compact_tombstones();
        Vault {
            payload,
            vmk,
            generation: self.generation,
            file_revision: Some(Sha256::digest(self.data).into()),
            password_revision: self.password_revision,
            password_wrap: self.password_wrap,
        }
    }
}

// ---------------------------------------------------------------------------
// File I/O
// ---------------------------------------------------------------------------

/// Read a bounded snapshot. Atomic replacement keeps an opened file coherent.
pub fn read_vault_file(path: &Path) -> Result<Vec<u8>, VaultError> {
    read_vault_reader(File::open(path).map_err(io_error)?)
}

/// Read a bounded encrypted vault or backup from a stream.
pub fn read_vault_reader(reader: impl Read) -> Result<Vec<u8>, VaultError> {
    let mut data = Vec::new();
    reader
        .take(MAX_VAULT_BYTES as u64 + 1)
        .read_to_end(&mut data)
        .map_err(io_error)?;
    ensure_size(data.len())?;
    Ok(data)
}

fn io_error(error: io::Error) -> VaultError {
    VaultError::Io(error.to_string())
}

enum FileWrite {
    Compare(Option<[u8; 32]>),
    Replace,
}

fn check_file_revision(path: &Path, expected: Option<[u8; 32]>) -> Result<(), VaultError> {
    match (File::open(path), expected) {
        (Ok(file), Some(expected)) => {
            let current: [u8; 32] = Sha256::digest(read_vault_reader(file)?).into();
            if current == expected {
                return Ok(());
            }
        }
        (Err(error), expected) if error.kind() == io::ErrorKind::NotFound => {
            if expected.is_none() {
                return Ok(());
            }
        }
        (Err(error), _) => return Err(io_error(error)),
        _ => {}
    }
    Err(VaultError::StaleFile)
}

/// Atomically replace a file. For read-modify-write, use [Vault::save_to_file].
pub fn write_vault_file(path: &Path, data: &[u8]) -> Result<(), VaultError> {
    commit_vault_file(path, data, FileWrite::Replace)
}

fn commit_vault_file(path: &Path, data: &[u8], mode: FileWrite) -> Result<(), VaultError> {
    ensure_size(data.len())?;
    let name = path
        .file_name()
        .ok_or_else(|| VaultError::Io("missing vault file name".into()))?;
    let mut lock_name = std::ffi::OsString::from(".");
    lock_name.push(name);
    lock_name.push(".lock");

    // Keep the sidecar in place so every writer locks the same inode across renames.
    let lock_file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path.with_file_name(lock_name))
        .map_err(io_error)?;
    let mut lock = fd_lock::RwLock::new(lock_file);
    let _guard = lock.write().map_err(io_error)?;

    // A rename replaces a symlink itself, while opening the file would read its target.
    match fs::symlink_metadata(path) {
        Ok(meta) if !meta.is_file() => {
            return Err(VaultError::Io(
                "vault destination is not a regular file".into(),
            ));
        }
        Ok(_) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(io_error(e)),
    };
    if let FileWrite::Compare(expected) = mode {
        check_file_revision(path, expected)?;
    }

    let dir = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let mut file = tempfile::Builder::new()
        .prefix(".otpvault-")
        .suffix(".tmp")
        .tempfile_in(dir)
        .map_err(io_error)?;
    file.write_all(data).map_err(io_error)?;
    file.as_file().sync_all().map_err(io_error)?;
    let tmp = file.into_temp_path();
    if matches!(mode, FileWrite::Compare(None)) {
        tmp.persist_noclobber(path).map_err(|e| {
            if e.error.kind() == io::ErrorKind::AlreadyExists {
                VaultError::StaleFile
            } else {
                io_error(e.error)
            }
        })?;
    } else {
        tmp.persist(path).map_err(|e| io_error(e.error))?;
    }
    // The rename is already committed in this process. A directory sync makes
    // it durable on filesystems that support it.
    #[cfg(unix)]
    let _ = File::open(dir).and_then(|dir| dir.sync_all());
    Ok(())
}

// ---------------------------------------------------------------------------
// Legacy v1 .otpbackup import
// ---------------------------------------------------------------------------

const V1_MAGIC: &[u8; 4] = b"OTPB";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct V1Payload {
    #[serde(default)]
    exported_at: Option<String>,
    #[serde(default)]
    accounts: Vec<V1Account>,
    #[serde(default)]
    folders: Vec<V1Folder>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct V1Account {
    #[serde(rename = "type")]
    otp_type: OtpType,
    secret: String,
    #[serde(default)]
    issuer: Option<String>,
    account_name: String,
    #[serde(default)]
    algorithm: Option<HashAlgorithm>,
    #[serde(default)]
    digits: Option<u32>,
    #[serde(default)]
    period: Option<u32>,
    #[serde(default)]
    counter: Option<u64>,
    #[serde(default)]
    folder_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct V1Folder {
    #[serde(default)]
    id: Option<String>,
    name: String,
    #[serde(default)]
    icon: Option<String>,
    #[serde(default)]
    color: Option<String>,
}

// The v1 payload uses `exportedAt`; accept both spellings defensively.
impl V1Payload {
    fn parse(bytes: &[u8]) -> Result<V1Payload, VaultError> {
        serde_json::from_slice(bytes)
            .map_err(|e| VaultError::Corrupt(format!("v1 payload json: {e}")))
    }
}

fn rfc3339_to_ms(s: &Option<String>, fallback: i64) -> i64 {
    match s {
        Some(v) => chrono::DateTime::parse_from_rfc3339(v)
            .map(|dt| dt.timestamp_millis())
            .unwrap_or(fallback),
        None => fallback,
    }
}

fn normalize_secret(secret: &str) -> String {
    secret
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '=')
        .collect::<String>()
        .to_uppercase()
}

/// Import a legacy v1 .otpbackup (docs/BACKUP_FORMAT.md: "OTPB" magic,
/// PBKDF2-SHA256 100k, AES-256-GCM; RFC 3339 timestamps → epoch ms).
pub fn import_backup_v1(
    data: &[u8],
    password: &str,
    now_ms: i64,
) -> Result<VaultPayload, VaultError> {
    ensure_size(data.len())?;
    // Layout: magic(4) version(4) salt(32) nonce(12) tag(16) ciphertext(..)
    const HEADER: usize = 4 + 4 + SALT_LEN + NONCE_LEN + TAG_LEN;
    if data.len() < HEADER {
        return Err(VaultError::Corrupt("v1 backup too short".into()));
    }
    if &data[0..4] != V1_MAGIC.as_slice() {
        return Err(VaultError::Corrupt("bad v1 magic".into()));
    }
    let version = u32::from_le_bytes([data[4], data[5], data[6], data[7]]);
    if version != 1 {
        return Err(VaultError::Corrupt(format!(
            "unsupported v1 version {version}"
        )));
    }
    let salt = &data[8..40];
    let nonce = &data[40..52];
    let tag = &data[52..68];
    let ct = &data[68..];

    let key = pbkdf2::pbkdf2_hmac_array::<sha2::Sha256, 32>(password.as_bytes(), salt, 100_000);

    // aes-gcm expects ciphertext with the tag appended.
    let mut ct_and_tag = Vec::with_capacity(ct.len() + TAG_LEN);
    ct_and_tag.extend_from_slice(ct);
    ct_and_tag.extend_from_slice(tag);

    let cipher = cipher_from(&key)?;
    let plaintext = cipher
        .decrypt(Nonce::from_slice(nonce), ct_and_tag.as_slice())
        .map_err(|_| VaultError::WrongPassword)?;

    let v1 = V1Payload::parse(&plaintext)?;
    let default_ts = rfc3339_to_ms(&v1.exported_at, now_ms);

    let accounts = v1
        .accounts
        .into_iter()
        .map(|a| OtpAccount {
            id: uuid::Uuid::new_v4().to_string(),
            otp_type: a.otp_type,
            secret: normalize_secret(&a.secret),
            issuer: a.issuer,
            account_name: a.account_name,
            algorithm: a.algorithm.unwrap_or(HashAlgorithm::Sha1),
            digits: a.digits.unwrap_or(6),
            period: a.period.unwrap_or(30),
            counter: a.counter.unwrap_or(0),
            folder_id: a.folder_id,
            is_favorite: false,
            sort_order: 0,
            icon: None,
            color: None,
            created_at: default_ts,
            updated_at: default_ts,
            deleted_at: None,
        })
        .collect();

    let folders = v1
        .folders
        .into_iter()
        .map(|f| OtpFolder {
            id: f.id.unwrap_or_else(|| uuid::Uuid::new_v4().to_string()),
            name: f.name,
            icon: f.icon,
            color: f.color,
            sort_order: 0,
            created_at: default_ts,
            updated_at: default_ts,
            deleted_at: None,
        })
        .collect();

    Ok(VaultPayload { accounts, folders })
}

#[cfg(test)]
mod tests {
    use super::Vault;

    #[test]
    fn an_unversioned_peer_cannot_replace_the_local_password_wrap() {
        let mut local = Vault::create("local-password").unwrap();
        let mut remote = local.clone();
        remote
            .change_password("local-password", "peer-password")
            .unwrap();
        remote.password_revision = None;
        let blob = remote.to_bytes(200).unwrap();
        let remote = local.open_peer(&blob).unwrap();

        assert!(!local.merge_password_wrap(&remote).unwrap());
        let blob = local.to_bytes(300).unwrap();
        assert!(Vault::open_with_password(&blob, "local-password").is_ok());
    }
}
