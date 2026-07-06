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
use std::path::Path;
use thiserror::Error;
use zeroize::Zeroize;

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
const NINETY_DAYS_MS: i64 = 90 * 24 * 60 * 60 * 1000;

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
}

// Encrypted payload wire representation (adds `version`).
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PayloadWireRef<'a> {
    version: u32,
    accounts: &'a [OtpAccount],
    folders: &'a [OtpFolder],
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
pub struct Vault {
    payload: VaultPayload,
    vmk: Vec<u8>,
    generation: u64,
    // KDF salt + wrapped VMK are preserved across saves so key-path opens can
    // re-serialize the header without knowing the password.
    kdf_salt: Vec<u8>,
    wrapped_nonce: Vec<u8>,
    wrapped_ct: Vec<u8>,
    kdf_m_kib: u32,
    kdf_t: u32,
    kdf_p: u32,
}

impl Drop for Vault {
    fn drop(&mut self) {
        self.vmk.zeroize();
    }
}

fn os_random(buf: &mut [u8]) {
    rand::rngs::OsRng.fill_bytes(buf);
}

fn argon2_kek(
    password: &str,
    salt: &[u8],
    m_kib: u32,
    t: u32,
    p: u32,
) -> Result<[u8; 32], VaultError> {
    let params = Params::new(m_kib, t, p, Some(VMK_LEN))
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

        let mut kek = argon2_kek(master_password, &salt, ARGON2_M_KIB, ARGON2_T, ARGON2_P)?;
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
            kdf_salt: salt,
            wrapped_nonce,
            wrapped_ct,
            kdf_m_kib: ARGON2_M_KIB,
            kdf_t: ARGON2_T,
            kdf_p: ARGON2_P,
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

    pub fn open_with_password(data: &[u8], master_password: &str) -> Result<Vault, VaultError> {
        let parsed = ParsedFile::parse(data)?;
        // Unwrap VMK with the password-derived KEK.
        let mut kek = argon2_kek(
            master_password,
            &parsed.kdf_salt,
            parsed.kdf_m_kib,
            parsed.kdf_t,
            parsed.kdf_p,
        )?;
        let unwrap = cipher_from(&kek).and_then(|c| {
            c.decrypt(
                Nonce::from_slice(&parsed.wrapped_nonce),
                parsed.wrapped_ct.as_slice(),
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

    /// Serialize with a fresh nonce; generation += 1; purge tombstones older
    /// than 90 days relative to `now_ms`.
    pub fn to_bytes(&mut self, now_ms: i64) -> Result<Vec<u8>, VaultError> {
        self.generation += 1;
        purge_tombstones(&mut self.payload, now_ms);

        let mut vault_nonce = vec![0u8; NONCE_LEN];
        os_random(&mut vault_nonce);

        let header = HeaderJson {
            kdf: KdfJson {
                algo: "argon2id".to_string(),
                m_kib: self.kdf_m_kib,
                t: self.kdf_t,
                p: self.kdf_p,
                salt: B64.encode(&self.kdf_salt),
            },
            wrapped_vmk: WrappedVmkJson {
                nonce: B64.encode(&self.wrapped_nonce),
                ct: B64.encode(&self.wrapped_ct),
            },
            vault_nonce: B64.encode(&vault_nonce),
            modified_at: now_ms,
            generation: self.generation,
        };
        let header_bytes = serde_json::to_vec(&header)
            .map_err(|e| VaultError::Crypto(format!("header encode: {e}")))?;

        let payload_json = serde_json::to_vec(&PayloadWireRef {
            version: PAYLOAD_VERSION,
            accounts: &self.payload.accounts,
            folders: &self.payload.folders,
        })
        .map_err(|e| VaultError::Crypto(format!("payload encode: {e}")))?;

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
        Ok(out)
    }

    /// Re-wrap the VMK under a new password-derived KEK (no payload re-encryption).
    pub fn change_password(&mut self, old: &str, new: &str) -> Result<(), VaultError> {
        // Verify the old password by unwrapping the stored VMK.
        let mut old_kek = argon2_kek(old, &self.kdf_salt, self.kdf_m_kib, self.kdf_t, self.kdf_p)?;
        let check = cipher_from(&old_kek).and_then(|c| {
            c.decrypt(
                Nonce::from_slice(&self.wrapped_nonce),
                self.wrapped_ct.as_slice(),
            )
            .map_err(|e| VaultError::Crypto(format!("unwrap vmk: {e}")))
        });
        old_kek.zeroize();
        let recovered = check.map_err(|_| VaultError::WrongPassword)?;
        if recovered != self.vmk {
            return Err(VaultError::WrongPassword);
        }

        // Fresh salt + nonce, re-wrap with the new KEK. Payload untouched.
        let mut new_salt = vec![0u8; SALT_LEN];
        os_random(&mut new_salt);
        let mut new_nonce = vec![0u8; NONCE_LEN];
        os_random(&mut new_nonce);
        let mut new_kek = argon2_kek(new, &new_salt, ARGON2_M_KIB, ARGON2_T, ARGON2_P)?;
        let wrap = cipher_from(&new_kek).and_then(|c| {
            c.encrypt(Nonce::from_slice(&new_nonce), self.vmk.as_slice())
                .map_err(|e| VaultError::Crypto(format!("rewrap vmk: {e}")))
        });
        new_kek.zeroize();
        let new_ct = wrap?;

        self.kdf_salt = new_salt;
        self.wrapped_nonce = new_nonce;
        self.wrapped_ct = new_ct;
        self.kdf_m_kib = ARGON2_M_KIB;
        self.kdf_t = ARGON2_T;
        self.kdf_p = ARGON2_P;
        Ok(())
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

fn purge_tombstones(payload: &mut VaultPayload, now_ms: i64) {
    let cutoff = now_ms - NINETY_DAYS_MS;
    payload
        .accounts
        .retain(|a| a.deleted_at.map(|d| d >= cutoff).unwrap_or(true));
    payload
        .folders
        .retain(|f| f.deleted_at.map(|d| d >= cutoff).unwrap_or(true));
}

// ---------------------------------------------------------------------------
// Parsed on-disk file (shared by both open paths)
// ---------------------------------------------------------------------------

struct ParsedFile {
    kdf_salt: Vec<u8>,
    kdf_m_kib: u32,
    kdf_t: u32,
    kdf_p: u32,
    wrapped_nonce: Vec<u8>,
    wrapped_ct: Vec<u8>,
    vault_nonce: Vec<u8>,
    generation: u64,
    aad: Vec<u8>,
    ciphertext: Vec<u8>,
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

impl ParsedFile {
    fn parse(data: &[u8]) -> Result<ParsedFile, VaultError> {
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
        let header_end = 16usize
            .checked_add(header_len)
            .ok_or_else(|| VaultError::Corrupt("header length overflow".into()))?;
        if header_end > data.len() {
            return Err(VaultError::Corrupt("header length exceeds file".into()));
        }
        let header_bytes = &data[16..header_end];
        let header: HeaderJson = serde_json::from_slice(header_bytes)
            .map_err(|e| VaultError::Corrupt(format!("header json: {e}")))?;

        let kdf_salt = b64_fixed(&header.kdf.salt, SALT_LEN, "salt")?;
        let wrapped_nonce = b64_fixed(&header.wrapped_vmk.nonce, NONCE_LEN, "wrapped nonce")?;
        let wrapped_ct = b64_fixed(&header.wrapped_vmk.ct, WRAPPED_CT_LEN, "wrapped ct")?;
        let vault_nonce = b64_fixed(&header.vault_nonce, NONCE_LEN, "vault nonce")?;

        let aad = data[..header_end].to_vec();
        let ciphertext = data[header_end..].to_vec();

        Ok(ParsedFile {
            kdf_salt,
            kdf_m_kib: header.kdf.m_kib,
            kdf_t: header.kdf.t,
            kdf_p: header.kdf.p,
            wrapped_nonce,
            wrapped_ct,
            vault_nonce,
            generation: header.generation,
            aad,
            ciphertext,
        })
    }

    /// Decrypt the payload with a raw VMK. GCM auth failure → `Crypto` (callers
    /// remap to WrongKey/WrongPassword); JSON failure → `Corrupt`.
    fn decrypt_payload(&self, vmk: &[u8]) -> Result<VaultPayload, VaultError> {
        let cipher = cipher_from(vmk)?;
        let plaintext = cipher
            .decrypt(
                Nonce::from_slice(&self.vault_nonce),
                Payload {
                    msg: &self.ciphertext,
                    aad: &self.aad,
                },
            )
            .map_err(|e| VaultError::Crypto(format!("decrypt payload: {e}")))?;
        let wire: PayloadWireOwned = serde_json::from_slice(&plaintext)
            .map_err(|e| VaultError::Corrupt(format!("payload json: {e}")))?;
        Ok(VaultPayload {
            accounts: wire.accounts,
            folders: wire.folders,
        })
    }

    fn into_vault(self, vmk: Vec<u8>, payload: VaultPayload) -> Vault {
        Vault {
            payload,
            vmk,
            generation: self.generation,
            kdf_salt: self.kdf_salt,
            wrapped_nonce: self.wrapped_nonce,
            wrapped_ct: self.wrapped_ct,
            kdf_m_kib: self.kdf_m_kib,
            kdf_t: self.kdf_t,
            kdf_p: self.kdf_p,
        }
    }
}

// ---------------------------------------------------------------------------
// File I/O
// ---------------------------------------------------------------------------

/// Read the whole vault file under a shared advisory lock.
pub fn read_vault_file(path: &Path) -> Result<Vec<u8>, VaultError> {
    use std::io::Read;
    let file = std::fs::File::open(path).map_err(|e| VaultError::Io(e.to_string()))?;
    let lock = fd_lock::RwLock::new(file);
    let guard = lock.read().map_err(|e| VaultError::Io(e.to_string()))?;
    let mut buf = Vec::new();
    (&*guard)
        .read_to_end(&mut buf)
        .map_err(|e| VaultError::Io(e.to_string()))?;
    Ok(buf)
}

/// Atomic write: temp file in same dir + fsync + rename, under an exclusive
/// advisory lock held on the destination file.
pub fn write_vault_file(path: &Path, data: &[u8]) -> Result<(), VaultError> {
    use std::io::Write;
    let dir = path.parent().filter(|p| !p.as_os_str().is_empty());
    let dir = dir.unwrap_or_else(|| Path::new("."));

    // Open (creating if needed) the destination purely to hold the advisory lock.
    let lock_file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)
        .map_err(|e| VaultError::Io(e.to_string()))?;
    let mut lock = fd_lock::RwLock::new(lock_file);
    let _guard = lock.write().map_err(|e| VaultError::Io(e.to_string()))?;

    let mut suffix = [0u8; 8];
    os_random(&mut suffix);
    let tmp = dir.join(format!(".otpvault-{}.tmp", hex(&suffix)));

    let write_result = (|| -> std::io::Result<()> {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(data)?;
        f.sync_all()?;
        Ok(())
    })();
    if let Err(e) = write_result {
        let _ = std::fs::remove_file(&tmp);
        return Err(VaultError::Io(e.to_string()));
    }

    if let Err(e) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(VaultError::Io(e.to_string()));
    }
    Ok(())
}

fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
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
