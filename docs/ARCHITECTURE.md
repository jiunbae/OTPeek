# Architecture v2 — Shared Rust Core

**Status**: Frozen contract for the big-bang migration. All public API signatures in this
document are binding. Implementation agents MUST NOT change public signatures; if a
signature turns out to be impossible to implement as written, keep the signature, add an
internal workaround, and flag it in your final report.

## 1. Goals

- One implementation of all logic (OTP algorithms, data model, vault crypto, sync) in Rust.
- Native UI shells kept: SwiftUI + WidgetKit (`apple/`), WinUI 3 (`windows/`).
- New first-class target: Linux/macOS CLI (`otpeek`).
- Secrets live in a single canonical **end-to-end-encrypted vault file**; platform
  keystores (Keychain / DPAPI / Secret Service) hold only the vault master key.
- Sync = encrypted blob moved by a dumb, pluggable backend (CloudKit, WebDAV).
  Merge logic lives in the Rust core, not in backends.
- Existing specs remain authoritative for algorithm behavior: `docs/SPEC.md` (RFC 6238 /
  4226 + test vectors), `docs/DATA_FORMAT.md` (field semantics). This document supersedes
  `docs/BACKUP_FORMAT.md` (v1 format becomes import-only legacy).

## 2. Repository layout (target state)

```
core/                          # Rust workspace
  Cargo.toml                   # workspace manifest, pinned shared deps
  crates/
    otpeek-core/                  # pure logic: TOTP/HOTP, base32, otpauth:// URIs,
                               #   Google Authenticator migration import, models
    otpeek-vault/                 # vault v2 container: Argon2id KEK, AES-256-GCM,
                               #   atomic file I/O, legacy .otpbackup v1 import
    otpeek-sync/                  # SyncBackend trait, merge engine, WebDAV backend
    otpeek-ffi/                   # UniFFI facade (OtpClient) exposed to Swift / C#
    otpeek-cli/                   # `otpeek` binary (clap)
apple/                         # SwiftUI apps + widget; consumes otpeek-ffi XCFramework
  scripts/build-core.sh        # builds XCFramework + generates Swift bindings
  Generated/                   # uniffi-generated Swift (gitignored, built on demand)
windows/                       # WinUI 3 app; consumes otpeek-ffi cdylib
  Otpeek.Interop/    # uniffi-bindgen-cs generated C# + native lib packaging
docs/                          # specs (this file, SPEC.md, DATA_FORMAT.md)
```

Legacy Swift logic (`apple/Shared/OtpGenerator.swift`, `AccountStore.swift`) and .NET
logic (`Otpeek.Core/Services/*`, `CloudSync/*`) are deleted after migration;
UI code is preserved.

## 3. Canonical data model

Model fields follow `docs/DATA_FORMAT.md` with these v2 changes:

- **Timestamps are `i64` Unix epoch milliseconds (UTC)** everywhere — in the Rust model,
  the vault JSON payload, and the FFI. (Legacy v1 JSON used RFC 3339 strings; the v1
  importer converts.) Rationale: deterministic merge comparison, trivial FFI.
- New field `deleted_at: Option<i64>` on accounts and folders — sync tombstone.
  Entities with `deleted_at != null` are hidden from all list APIs and purged after
  90 days (purge happens during vault save).
- `icon_url` in DATA_FORMAT maps to `icon` here (string, URL or platform asset name).

### Rust types (`otpeek-core::types`) — frozen

```rust
pub enum OtpType { Totp, Hotp }
pub enum HashAlgorithm { Sha1, Sha256, Sha512 }

pub struct OtpAccount {
    pub id: String,                 // UUID v4, lowercase hyphenated
    pub otp_type: OtpType,
    pub secret: String,             // Base32 (RFC 4648, no padding required on input;
                                    //   stored normalized: uppercase, padding stripped)
    pub issuer: Option<String>,
    pub account_name: String,
    pub algorithm: HashAlgorithm,   // default Sha1
    pub digits: u32,                // 6..=8, default 6
    pub period: u32,                // TOTP only, default 30
    pub counter: u64,               // HOTP only, default 0
    pub folder_id: Option<String>,
    pub is_favorite: bool,
    pub sort_order: i32,
    pub icon: Option<String>,
    pub color: Option<String>,      // "#RRGGBB"
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
}

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

pub struct OtpCode {
    pub code: String,          // zero-padded, `digits` chars
    pub valid_from: i64,       // epoch ms, start of current period (TOTP); for HOTP = generation time
    pub valid_until: i64,      // epoch ms, end of period; for HOTP = i64::MAX
}
```

Serde: all JSON uses `camelCase` field names (`serde(rename_all = "camelCase")`),
`otp_type` serializes as `"type"` with values `"totp"` / `"hotp"`, algorithm as
`"SHA1" | "SHA256" | "SHA512"`. Optional fields are omitted when `None`
(`skip_serializing_if = "Option::is_none"`).

## 4. `otpeek-core` — public API (frozen)

```rust
pub enum CoreError {
    InvalidSecret(String),
    InvalidUri(String),
    InvalidParameter(String),
}

// Algorithms — must pass RFC 4226 / RFC 6238 vectors in docs/SPEC.md.
pub fn generate_totp(secret_b32: &str, algorithm: HashAlgorithm, digits: u32,
                     period: u32, unix_time_secs: i64) -> Result<String, CoreError>;
pub fn generate_hotp(secret_b32: &str, algorithm: HashAlgorithm, digits: u32,
                     counter: u64) -> Result<String, CoreError>;
// Convenience over an account; does NOT mutate HOTP counter.
pub fn generate_code(account: &OtpAccount, unix_time_ms: i64) -> Result<OtpCode, CoreError>;

// otpauth:// (Google Authenticator compatible; see SPEC.md §URI Format).
// Fills id (new UUID), created_at/updated_at (caller passes now_ms).
pub fn parse_otpauth_uri(uri: &str, now_ms: i64) -> Result<OtpAccount, CoreError>;
pub fn to_otpauth_uri(account: &OtpAccount) -> String;

// otpauth-migration://offline?data=... (Google Authenticator export QR, protobuf).
pub fn parse_migration_uri(uri: &str, now_ms: i64) -> Result<Vec<OtpAccount>, CoreError>;

// Base32 helpers (RFC 4648, case-insensitive input, '=' padding optional).
pub fn validate_secret(secret_b32: &str) -> bool;
pub fn normalize_secret(secret_b32: &str) -> Result<String, CoreError>; // uppercase, strip pad/spaces
```

Notes:
- HMAC offset is taken from the **last byte** of the HMAC output (`hmac[len-1] & 0x0F`),
  which generalizes the SHA1 formula in SPEC.md to SHA256/512.
- The `19` in SPEC.md's formula is SHA1-specific; implement per RFC.
- No `std::time` calls inside otpeek-core — time is always a parameter (testability).

## 5. `otpeek-vault` — vault container v2

### 5.1 Key hierarchy

- **VMK (Vault Master Key)**: random 32 bytes, generated once at vault creation.
  Encrypts the payload. Never changes except explicit rotation.
- **KEK**: `Argon2id(master_password, salt)` → 32 bytes. Wraps the VMK.
  Params (frozen): `m = 65536 KiB (64 MiB), t = 3, p = 1`, salt 32 random bytes.
- Locally, platforms store the **raw VMK** in the native keystore for password-less
  unlock (Keychain / DPAPI / Secret Service). The master password is only needed for:
  vault creation, new-device bootstrap, password change, and opening a vault file
  without a keystore entry. **Argon2 never runs in widget processes.**
- Password change re-wraps the VMK (no payload re-encryption). Key rotation
  (new VMK) is out of scope for v2.

### 5.2 File format (`.otpvault`, also used for backup export and the remote sync blob)

```
[8 bytes]  Magic: "OTPVAULT" (ASCII)
[4 bytes]  Format version: u32 LE = 2
[4 bytes]  Header length H: u32 LE
[H bytes]  Header: UTF-8 JSON (see below)
[rest]     Ciphertext: AES-256-GCM(key = VMK, nonce = header.vaultNonce,
           aad = magic || version || header bytes), 16-byte tag appended.
```

Header JSON:

```json
{
  "kdf": { "algo": "argon2id", "mKib": 65536, "t": 3, "p": 1, "salt": "<base64 32B>" },
  "wrappedVmk": { "nonce": "<base64 12B>", "ct": "<base64 48B>" },
  "vaultNonce": "<base64 12B>",
  "modifiedAt": 1730000000000,
  "generation": 42
}
```

- `wrappedVmk.ct` = AES-256-GCM(key = KEK, nonce, plaintext = VMK) — 32B + 16B tag.
- `vaultNonce` is regenerated on **every** save (never reuse a nonce with the same VMK).
- `generation` is a monotonically increasing save counter (used as a merge tiebreaker).

Decrypted payload JSON:

```json
{
  "version": 2,
  "accounts": [ /* OtpAccount, camelCase, includes tombstones */ ],
  "folders":  [ /* OtpFolder */ ]
}
```

### 5.3 Public API (frozen)

```rust
pub enum VaultError {
    WrongPassword,           // KEK unwrap or payload auth failure
    WrongKey,
    Corrupt(String),         // bad magic/version/header/json
    Io(String),
    Crypto(String),
    Core(CoreError),
}

pub struct VaultPayload { pub accounts: Vec<OtpAccount>, pub folders: Vec<OtpFolder> }

pub struct Vault { /* payload + header state; NOT Sync — wrap in Mutex above */ }

impl Vault {
    pub fn create(master_password: &str) -> Result<Vault, VaultError>;      // fresh VMK
    pub fn vmk(&self) -> Vec<u8>;                                           // 32 bytes
    // Parse + decrypt from bytes:
    pub fn open_with_key(data: &[u8], vmk: &[u8]) -> Result<Vault, VaultError>;
    pub fn open_with_password(data: &[u8], master_password: &str) -> Result<Vault, VaultError>;
    // Serialize (fresh nonce, generation += 1, purge tombstones > 90 days old vs now_ms):
    pub fn to_bytes(&mut self, now_ms: i64) -> Result<Vec<u8>, VaultError>;
    pub fn change_password(&mut self, old: &str, new: &str) -> Result<(), VaultError>;
    pub fn payload(&self) -> &VaultPayload;
    pub fn payload_mut(&mut self) -> &mut VaultPayload;
    pub fn generation(&self) -> u64;
}

// Atomic file I/O: write temp file in same dir + fsync + rename. Advisory lock
// (fd-lock) around read-modify-write so app and widget processes don't race.
pub fn read_vault_file(path: &Path) -> Result<Vec<u8>, VaultError>;
pub fn write_vault_file(path: &Path, data: &[u8]) -> Result<(), VaultError>;

// Legacy import: v1 .otpbackup (see docs/BACKUP_FORMAT.md: "OTPB" magic, PBKDF2-SHA256
// 100k, AES-256-GCM, RFC3339 timestamps → convert to epoch ms).
pub fn import_backup_v1(data: &[u8], password: &str, now_ms: i64)
    -> Result<VaultPayload, VaultError>;
```

## 6. `otpeek-sync` — sync engine

### 6.1 Backend abstraction (frozen)

Backends move opaque bytes; they never see plaintext. Blocking API (FFI-friendly;
platforms bridge async natively).

```rust
pub struct RemoteBlob { pub data: Vec<u8>, pub etag: Option<String> }

pub enum SyncError {
    NotConfigured, Network(String), Auth(String),
    Conflict,                      // store() precondition failed
    Backend(String), Vault(VaultError),
}

pub trait SyncBackend: Send + Sync {
    fn fetch(&self) -> Result<Option<RemoteBlob>, SyncError>;   // None = no remote vault yet
    // if_match: Some(etag) → fail with Conflict if remote changed; None → create only
    //   (fail with Conflict if a blob already exists).
    fn store(&self, data: Vec<u8>, if_match: Option<String>) -> Result<String, SyncError>;
}
```

Implementations:
- **WebDAV** (in `otpeek-sync`, feature `webdav`, `ureq` + rustls): single file
  `otpeek-vault.otpvault` at a configured URL; ETag / `If-Match` / `If-None-Match: *`
  for optimistic concurrency; Basic auth.
- **CloudKit** (Swift, in `apple/`): implements the FFI mirror of this trait
  (see §7). Private DB, record type `Vault`, record name `"vault"`, blob in a
  `bytes` field (or CKAsset if > 1 MB), `recordChangeTag` as etag.
- Windows OneDrive/Google Drive providers from the legacy app are dropped in v2
  (WebDAV + manual export cover the need; can return later as C#-side backends).

### 6.2 Merge rules (frozen)

Per-entity (accounts and folders independently), matched by `id`:

1. Present on one side only → keep it.
2. Present on both → the one with greater `updated_at` wins entirely (LWW).
   Tie → the one with `deleted_at` set wins; still tied → lexicographically
   greater `id` wins (any deterministic tiebreak is fine, but be deterministic).
3. Exception: `counter` (HOTP) = `max(local.counter, remote.counter)` regardless
   of which side won LWW (never reuse an HOTP counter).
4. Tombstones merge like normal entities (deletion propagates via `deleted_at`).

### 6.3 Engine (frozen)

```rust
pub struct SyncOutcome { pub pushed: bool, pub pulled: bool, pub merged_changes: u32 }

pub struct SyncEngine;
impl SyncEngine {
    /// fetch → decrypt remote with local VMK → merge → save merged locally (via
    /// callback) → store remote with if_match, retry on Conflict (max 3, refetch+remerge).
    /// If remote is None: push local. If remote can't decrypt with VMK: SyncError::Vault(WrongKey)
    /// (caller resolves by re-bootstrapping with master password).
    pub fn sync(local: &mut Vault, backend: &dyn SyncBackend, now_ms: i64)
        -> Result<SyncOutcome, SyncError>;
    pub fn merge(local: &VaultPayload, remote: &VaultPayload) -> (VaultPayload, u32);
}
```

Bootstrap on a new device: fetch remote blob → `Vault::open_with_password` → stash VMK
in platform keystore → save locally. This is platform-side glue using the APIs above.

## 7. `otpeek-ffi` — UniFFI facade (frozen surface)

UniFFI **0.29.x**, proc-macro mode (no UDL). `crate-type = ["staticlib", "cdylib", "lib"]`,
namespace `otpeek`. All FFI types live in this crate (converted from core types).
C# generation via `uniffi-bindgen-cs` (v0.9.x, matching uniffi 0.29), Swift via
`uniffi-bindgen generate --library`.

Exposed records/enums mirror §3 exactly: `OtpAccount`, `OtpFolder`, `OtpCode`,
`OtpType`, `HashAlgorithm`, plus:

```rust
#[derive(uniffi::Error)]
pub enum OtpError {   // flattened union of Core/Vault/Sync errors
    InvalidSecret(String), InvalidUri(String), InvalidParameter(String),
    WrongPassword, WrongKey, Corrupt(String), Io(String), Crypto(String),
    NotConfigured, Network(String), Auth(String), Conflict, Backend(String),
}

#[uniffi::export(with_foreign)]        // Swift/C# can implement (CloudKit, etc.)
pub trait SyncBackend: Send + Sync {
    fn fetch(&self) -> Result<Option<RemoteBlob>, OtpError>;
    fn store(&self, data: Vec<u8>, if_match: Option<String>) -> Result<String, OtpError>;
}

#[derive(uniffi::Object)]
pub struct OtpClient { /* Mutex<Vault> + vault_path + Mutex<Option<Arc<dyn SyncBackend>>> */ }

#[uniffi::export]
impl OtpClient {
    // --- lifecycle ---
    #[uniffi::constructor]
    pub fn create(vault_path: String, master_password: String) -> Result<Arc<Self>, OtpError>;
    #[uniffi::constructor]
    pub fn open_with_key(vault_path: String, vmk: Vec<u8>) -> Result<Arc<Self>, OtpError>;
    #[uniffi::constructor]
    pub fn open_with_password(vault_path: String, master_password: String) -> Result<Arc<Self>, OtpError>;
    /// Bootstrap from a remote/backup blob onto this device.
    #[uniffi::constructor]
    pub fn restore(vault_path: String, blob: Vec<u8>, master_password: String) -> Result<Arc<Self>, OtpError>;

    pub fn vault_key(&self) -> Vec<u8>;              // for the platform keystore
    pub fn reload(&self) -> Result<(), OtpError>;    // re-read file (widget/app coherence)
    pub fn change_password(&self, old: String, new: String) -> Result<(), OtpError>;

    // --- accounts (list APIs exclude tombstones, sorted by sort_order then issuer) ---
    pub fn list_accounts(&self) -> Vec<OtpAccount>;
    pub fn get_account(&self, id: String) -> Option<OtpAccount>;
    /// id may be "" → assigned; created_at/updated_at always set by core.
    pub fn add_account(&self, account: OtpAccount) -> Result<OtpAccount, OtpError>;
    pub fn add_from_uri(&self, uri: String) -> Result<Vec<OtpAccount>, OtpError>; // otpauth:// or otpauth-migration://
    pub fn update_account(&self, account: OtpAccount) -> Result<OtpAccount, OtpError>;
    pub fn delete_account(&self, id: String) -> Result<(), OtpError>;             // sets tombstone

    // --- folders ---
    pub fn list_folders(&self) -> Vec<OtpFolder>;
    pub fn add_folder(&self, folder: OtpFolder) -> Result<OtpFolder, OtpError>;
    pub fn update_folder(&self, folder: OtpFolder) -> Result<OtpFolder, OtpError>;
    pub fn delete_folder(&self, id: String) -> Result<(), OtpError>; // accounts keep living, folder_id cleared

    // --- codes ---
    pub fn code(&self, id: String, unix_time_ms: i64) -> Result<OtpCode, OtpError>;   // TOTP (or HOTP peek)
    pub fn next_hotp(&self, id: String) -> Result<OtpCode, OtpError>;                 // increments + persists
    pub fn codes_at(&self, unix_time_ms: i64) -> Vec<AccountCode>;                    // all TOTP accounts, for widgets

    // --- backup / sync ---
    pub fn export_backup(&self, password: String) -> Result<Vec<u8>, OtpError>;       // v2 container
    /// merge=true: adds unknown ids and resurrects locally-tombstoned entities
    /// that are live in the backup (updated_at bumped to now, so a later sync's
    /// LWW merge can't re-delete them); tombstones inside the backup are
    /// skipped. merge=false: replaces the whole payload. Returns import count.
    pub fn import_backup(&self, data: Vec<u8>, password: String, merge: bool) -> Result<u32, OtpError>;
    pub fn import_backup_v1(&self, data: Vec<u8>, password: String, merge: bool) -> Result<u32, OtpError>;
    pub fn set_sync_backend(&self, backend: Arc<dyn SyncBackend>);
    pub fn clear_sync_backend(&self);
    pub fn sync(&self, unix_time_ms: i64) -> Result<SyncOutcome, OtpError>;
}

#[derive(uniffi::Record)] pub struct AccountCode { pub account: OtpAccount, pub code: OtpCode }
#[derive(uniffi::Record)] pub struct RemoteBlob { pub data: Vec<u8>, pub etag: Option<String> }
#[derive(uniffi::Record)] pub struct SyncOutcome { pub pushed: bool, pub pulled: bool, pub merged_changes: u32 }

// Free functions (widget preview, validation UX):
#[uniffi::export] pub fn parse_otpauth_uri(uri: String, now_ms: i64) -> Result<OtpAccount, OtpError>;
#[uniffi::export] pub fn account_to_uri(account: OtpAccount) -> String;
#[uniffi::export] pub fn validate_secret(secret: String) -> bool;
#[uniffi::export] pub fn generate_totp_now(secret: String, algorithm: HashAlgorithm,
    digits: u32, period: u32, unix_time_secs: i64) -> Result<String, OtpError>;
```

Every mutating call persists to `vault_path` immediately (atomic write under the
advisory lock). `OtpClient` is `Send + Sync`; internal `Mutex` serializes access.
Change notification across processes (app ↔ widget) is platform-side
(Darwin notifications / file watcher) — not in core.

## 8. `otpeek-cli` — the `otpeek` binary

- Binary name `otpeek`. Targets: `aarch64/x86_64-unknown-linux-{gnu,musl}`, macOS, Windows.
- Depends only on `otpeek-core`, `otpeek-vault`, `otpeek-sync` (not otpeek-ffi).
- Vault path: `$OTPEEK_VAULT` env → `--vault` flag → XDG default
  `~/.local/share/otpeek/vault.otpvault`. Config: `~/.config/otpeek/config.toml`
  (sync backend settings only — never secrets).
- VMK storage: `keyring` crate (Secret Service / macOS Keychain / Windows Credential
  Manager), service `"otpeek"`, user = vault path. Fallback when no keystore
  (headless): prompt for master password (`rpassword`), or `$OTPEEK_VAULT_PASSWORD`.
- WebDAV password: keyring entry `"otpeek-webdav"`, or `$OTP_WEBDAV_PASSWORD`.

Commands (clap v4, kebab-case):

```
otp init                                     # create vault (prompts password twice)
otp add <otpauth-uri>                        # also accepts otpauth-migration://
otp add --issuer GitHub --account me [--secret -] [--hotp] [--digits N] [--period N] [--algorithm sha256]
otp list [--folder NAME] [--json]            # table: index, issuer, account, folder, fav
otp code <query> [--copy] [--watch]          # query: index | fuzzy issuer/account match;
                                             #   ambiguous → list matches, exit 2
otp uri <query>                              # print otpauth:// URI
otp qr <query>                               # render QR to terminal (qrcode crate)
otp rm <query> [--yes]
otp edit <query> [--issuer X] [--account X] [--folder NAME|--no-folder] [--favorite|--no-favorite]
otp folder list|add <name>|rm <name>
otp export <file> [--password-stdin]         # v2 container
otp import <file> [--merge] [--legacy]       # --legacy = v1 .otpbackup
otp sync setup webdav <url> --user <u>       # prompts password, stores in keyring
otp sync now | otp sync status
otp restore <file-or-webdav-url>             # new-device bootstrap
otp passwd                                   # change master password
```

Output: human tables to stdout, errors to stderr, exit codes 0/1/2 (ok/error/ambiguous).
`--json` on list/code for scripting. `--watch` redraws TOTP with a countdown.

## 9. Apple integration (`apple/`)

1. **Build plumbing**: `apple/scripts/build-core.sh` —
   `cargo build -p otpeek-ffi --release` for `aarch64-apple-darwin`, `aarch64-apple-ios`,
   `aarch64-apple-ios-sim` → `xcodebuild -create-xcframework` → `apple/Frameworks/OtpCore.xcframework`;
   `uniffi-bindgen generate --library ... --language swift` → `apple/Generated/`.
   Wire as a pre-build script phase in `project.yml` (XcodeGen), or committed build output.
2. **Replace logic**: delete `OtpGenerator.swift`, `AccountStore.swift` internals;
   introduce `OtpStore` (ObservableObject) wrapping `OtpClient`. Keychain keeps ONLY
   the VMK: account `"vmk"`, access group shared with the widget,
   `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
   Vault file lives in the App Group container:
   `FileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.otpeek.app")/vault.otpvault`.
3. **Widget**: opens `OtpClient.openWithKey` (keychain VMK + shared vault path),
   `codesAt(...)` for timeline entries. No Argon2, no password UI in the widget.
   App posts a Darwin notification (`CFNotificationCenterGetDarwinNotifyCenter`) +
   `WidgetCenter.reloadAllTimelines()` after each mutation.
4. **CloudKit backend**: Swift class `CloudKitSyncBackend: SyncBackend` (the uniffi
   foreign trait). Container `iCloud.com.otpeek.app`, private DB, record type
   `Vault`, recordName `"vault"`, `blob: Data` field, `recordChangeTag` as etag;
   `if_match` maps to save policy `.ifServerRecordUnchanged` (translate CKError
   `.serverRecordChanged` → `OtpError.Conflict`). Bridge async CloudKit with a semaphore
   (the trait is blocking; call sync() off the main thread).
5. **Migration on first launch**: if no vault file and legacy data exists
   (UserDefaults `otp_accounts` + keychain `secret_<id>` entries) → onboarding screen
   asks user to create a master password → `OtpClient.create` → insert legacy accounts
   (convert RFC3339 → epoch ms) → verify count → rename legacy UserDefaults keys to
   `migrated_*` (keep one release as safety net).
6. **UI kept**: all views under `apple/Otpeek/Views/` and the widget UI stay;
   only their data layer moves to `OtpStore`. Update `project.yml` and entitlements
   (add CloudKit capability).

## 10. Windows integration (`windows/`)

1. **Interop project** `windows/Otpeek.Interop/`: C# generated by
   `uniffi-bindgen-cs` from the otpeek-ffi cdylib (`otp.dll`), plus MSBuild targets that
   run `cargo build -p otpeek-ffi --release --target x86_64-pc-windows-msvc` (and arm64)
   and copy the DLL into the output. Generated file committed (regenerate script:
   `windows/scripts/generate-bindings.ps1`).
2. **Replace**: `OtpService`, `EncryptionService`, `AccountRepository`, `BackupService`,
   `SyncManager`, `CloudSync/*` are removed; ViewModels call a new
   `OtpClientService` (DI singleton) wrapping `OtpClient`.
   `SecureStorageService` shrinks to: DPAPI-protect the VMK in
   `%LOCALAPPDATA%\Otpeek\vmk.bin`. Vault:
   `%LOCALAPPDATA%\Otpeek\vault.otpvault`.
3. **Sync**: WebDAV is built into the core — settings UI configures URL/user/password
   (password DPAPI-protected). OneDrive/GDrive UI removed.
4. **Migration**: on startup, if legacy `accounts.json` exists and no vault →
   password-creation dialog → import → rename legacy file to `accounts.json.migrated`.
5. **Widget/tray**: `OtpWidgetDataProvider` reads via `OtpClient` (open with DPAPI VMK).
6. ⚠️ Cannot be compiled on macOS — this workstream is code-complete-only; verified
   later on a Windows machine.

## 11. Dependencies (pinned in `core/Cargo.toml` [workspace.dependencies])

| Crate | Version | Used by |
|---|---|---|
| hmac, sha1, sha2 | 0.12 / 0.10 / 0.10 | otpeek-core |
| data-encoding (base32) | 2 | otpeek-core |
| url | 2 | otpeek-core |
| uuid (v4) | 1 | otpeek-core |
| prost (migration protobuf) | 0.13 | otpeek-core (hand-rolled varint decode is also acceptable) |
| serde, serde_json | 1 | all |
| thiserror | 2 | all |
| aes-gcm | 0.10 | otpeek-vault |
| argon2 | 0.5 | otpeek-vault |
| rand (OsRng via getrandom) | 0.8 | otpeek-vault |
| zeroize | 1 | otpeek-vault |
| fd-lock | 4 | otpeek-vault |
| ureq (rustls, no default tls) | 2 | otpeek-sync |
| uniffi | 0.29 | otpeek-ffi |
| clap | 4 | otpeek-cli |
| keyring | 3 | otpeek-cli |
| rpassword, comfy-table, qrcode, arboard | latest | otpeek-cli |

## 12. Testing

- **otpeek-core**: RFC 4226/6238 vectors from `docs/SPEC.md` (all three SHA variants for
  TOTP per RFC 6238 Appendix B), URI round-trips, migration payload decode, base32 edge
  cases (lowercase, padding, invalid chars).
- **otpeek-vault**: round-trip create→save→open (key and password paths), wrong password →
  `WrongPassword`, corrupt/truncated data → `Corrupt`, AAD tamper detection, v1 backup
  import against a fixture generated with the documented v1 parameters, tombstone purge.
  Commit a small fixture `core/crates/otpeek-vault/tests/fixtures/vault-v2.otpvault`
  (password `"test-password-123"`) so future refactors can't silently break the format.
- **otpeek-sync**: merge property tests (LWW, tombstone, counter-max, determinism),
  engine tests with an in-memory `SyncBackend` (including etag-conflict retry).
- **otpeek-cli**: integration tests via `assert_cmd` with `$OTPEEK_VAULT_PASSWORD` and a temp
  vault dir (no keyring in CI).
- **apple**: existing UI preserved; add an XCTest that round-trips add→code against the
  real core, and RFC vector checks through the FFI.
- CI (later): GitHub Actions matrix `cargo test` (macOS + Ubuntu + Windows), xcodebuild.

## 13. Parallel workstream ownership (big-bang plan)

| WS | Owner agent | Owns (exclusive write access) | Deliverable |
|----|-------------|-------------------------------|-------------|
| A | core | `core/crates/otpeek-core/` | algorithms/models/URI/migration + tests green |
| B | vault-sync | `core/crates/otpeek-vault/`, `core/crates/otpeek-sync/` | vault v2 + engine + WebDAV + tests green |
| C | ffi-cli | `core/crates/otpeek-ffi/`, `core/crates/otpeek-cli/` | facade wired + CLI e2e |
| D | apple | `apple/` | app+widget on core, CloudKit backend, migration |
| E | windows | `windows/` | app+widget on interop, DPAPI VMK, migration (build-unverified) |

Ground rules for all agents:
- The workspace skeleton (crate layout, manifests, stub signatures) already exists —
  fill in bodies; **do not** rename crates/modules or alter public signatures.
- You may add private modules, dev-dependencies, and internal helpers freely inside
  your owned directories. Do not edit files outside them (report needed changes instead).
- Do not `git commit`; leave changes in the working tree.
- Rust: 2021 edition idioms, `cargo fmt` clean, no `unwrap()` outside tests.
- Stubs are `todo!()` — cross-crate `cargo test` may panic where a dependency isn't
  filled in yet; only your own crate's tests must pass at hand-off. Integration pass
  (after all WS land) runs the full suite and reconciles drift.

## 14. Security notes

- Secrets exist in plaintext only inside process memory of an unlocked client;
  `zeroize` VMK/KEK buffers on drop.
- Widgets display codes without auth by design (same as v1) — document the tradeoff;
  a future `require_auth` account flag can gate keychain access behind biometrics.
- Vault file at rest = AES-256-GCM with a random 256-bit key; brute force applies to
  the keystore (device security) or Argon2id(password) for the remote blob.
- Clipboard writes (CLI `--copy`, apps) should be flagged transient where supported;
  no auto-clear in v2 (note in README).
- PBKDF2 100k (v1) is import-only; all new writes are Argon2id.
