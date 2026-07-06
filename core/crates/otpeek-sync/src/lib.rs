//! otpeek-sync: pluggable encrypted-blob sync — SyncBackend trait, merge engine,
//! WebDAV backend. See docs/ARCHITECTURE.md §6 (frozen contract).

use otpeek_core::{OtpAccount, OtpFolder};
use otpeek_vault::{Vault, VaultError, VaultPayload};
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteBlob {
    pub data: Vec<u8>,
    pub etag: Option<String>,
}

#[derive(Debug, Error)]
pub enum SyncError {
    #[error("sync not configured")]
    NotConfigured,
    #[error("network error: {0}")]
    Network(String),
    #[error("auth error: {0}")]
    Auth(String),
    #[error("remote changed concurrently")]
    Conflict,
    #[error("backend error: {0}")]
    Backend(String),
    #[error(transparent)]
    Vault(#[from] VaultError),
}

/// Backends move opaque encrypted bytes; they never see plaintext.
/// Blocking by design (FFI-friendly); platforms bridge async natively.
pub trait SyncBackend: Send + Sync {
    /// `None` = no remote vault exists yet.
    fn fetch(&self) -> Result<Option<RemoteBlob>, SyncError>;
    /// `if_match`: Some(etag) → fail with `Conflict` if remote changed;
    /// None → create-only (fail with `Conflict` if a blob already exists).
    /// Returns the new etag.
    fn store(&self, data: Vec<u8>, if_match: Option<String>) -> Result<String, SyncError>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SyncOutcome {
    pub pushed: bool,
    pub pulled: bool,
    pub merged_changes: u32,
}

pub struct SyncEngine;

const MAX_ATTEMPTS: u32 = 3;

impl SyncEngine {
    /// fetch → decrypt remote with local VMK → merge (§6.2) → mutate `local`
    /// in place (caller persists) → store with if_match; on `Conflict` refetch,
    /// re-merge and retry (max 3).
    pub fn sync(
        local: &mut Vault,
        backend: &dyn SyncBackend,
        now_ms: i64,
    ) -> Result<SyncOutcome, SyncError> {
        for _ in 0..MAX_ATTEMPTS {
            match backend.fetch()? {
                None => {
                    // No remote yet: create-only push of the local vault.
                    let bytes = local.to_bytes(now_ms)?;
                    match backend.store(bytes, None) {
                        Ok(_) => {
                            return Ok(SyncOutcome {
                                pushed: true,
                                pulled: false,
                                merged_changes: 0,
                            })
                        }
                        Err(SyncError::Conflict) => continue, // blob appeared; refetch + merge
                        Err(e) => return Err(e),
                    }
                }
                Some(blob) => {
                    let vmk = local.vmk();
                    let remote = Vault::open_with_key(&blob.data, &vmk).map_err(|e| match e {
                        VaultError::WrongKey => SyncError::Vault(VaultError::WrongKey),
                        // Any decrypt failure with the local VMK is treated as a key
                        // problem the caller resolves via password re-bootstrap.
                        VaultError::Crypto(_) => SyncError::Vault(VaultError::WrongKey),
                        other => SyncError::Vault(other),
                    })?;

                    let (merged, changes) = Self::merge(local.payload(), remote.payload());
                    let pulled = changes > 0;
                    *local.payload_mut() = merged;

                    let bytes = local.to_bytes(now_ms)?;
                    match backend.store(bytes, blob.etag) {
                        Ok(_) => {
                            return Ok(SyncOutcome {
                                pushed: true,
                                pulled,
                                merged_changes: changes,
                            })
                        }
                        Err(SyncError::Conflict) => continue, // remote moved; refetch + remerge
                        Err(e) => return Err(e),
                    }
                }
            }
        }
        Err(SyncError::Conflict)
    }

    /// Pure merge per docs/ARCHITECTURE.md §6.2 (LWW by updated_at, tombstone
    /// tiebreak, HOTP counter = max). Returns (merged, changed-entity count).
    pub fn merge(local: &VaultPayload, remote: &VaultPayload) -> (VaultPayload, u32) {
        let (accounts, acct_changes) = merge_accounts(&local.accounts, &remote.accounts);
        let (folders, folder_changes) = merge_folders(&local.folders, &remote.folders);
        (
            VaultPayload { accounts, folders },
            acct_changes + folder_changes,
        )
    }
}

// ---------------------------------------------------------------------------
// Merge internals
// ---------------------------------------------------------------------------

/// Deterministic per-entity merge, matched by id. `winner` picks between two
/// entities present on both sides. Order-independent (commutative in content).
fn merge_entities<T, F>(
    local: &[T],
    remote: &[T],
    id_of: impl Fn(&T) -> &str,
    winner: F,
) -> (Vec<T>, u32)
where
    T: Clone + PartialEq,
    F: Fn(&T, &T) -> T,
{
    use std::collections::BTreeMap;
    let local_map: BTreeMap<&str, &T> = local.iter().map(|e| (id_of(e), e)).collect();
    let remote_map: BTreeMap<&str, &T> = remote.iter().map(|e| (id_of(e), e)).collect();

    // Union of ids in a deterministic (sorted) order.
    let mut ids: Vec<&str> = local_map.keys().copied().collect();
    for k in remote_map.keys() {
        if !local_map.contains_key(k) {
            ids.push(k);
        }
    }
    ids.sort_unstable();

    let mut out = Vec::with_capacity(ids.len());
    let mut changes = 0u32;
    for id in ids {
        let chosen = match (local_map.get(id), remote_map.get(id)) {
            (Some(l), Some(r)) => winner(l, r),
            (Some(l), None) => (*l).clone(),
            (None, Some(r)) => (*r).clone(),
            (None, None) => unreachable!(),
        };
        // Count entities that differ from the LOCAL side (new or modified).
        match local_map.get(id) {
            Some(l) if **l == chosen => {}
            _ => changes += 1,
        }
        out.push(chosen);
    }
    (out, changes)
}

fn merge_accounts(local: &[OtpAccount], remote: &[OtpAccount]) -> (Vec<OtpAccount>, u32) {
    merge_entities(
        local,
        remote,
        |a| a.id.as_str(),
        |l, r| {
            let mut winner = pick(
                l,
                r,
                l.updated_at,
                r.updated_at,
                l.deleted_at.is_some(),
                r.deleted_at.is_some(),
            )
            .clone();
            // HOTP counter never regresses regardless of LWW winner.
            winner.counter = l.counter.max(r.counter);
            winner
        },
    )
}

fn merge_folders(local: &[OtpFolder], remote: &[OtpFolder]) -> (Vec<OtpFolder>, u32) {
    merge_entities(
        local,
        remote,
        |f| f.id.as_str(),
        |l, r| {
            pick(
                l,
                r,
                l.updated_at,
                r.updated_at,
                l.deleted_at.is_some(),
                r.deleted_at.is_some(),
            )
            .clone()
        },
    )
}

/// LWW winner selection (§6.2): greater `updated_at`; tie → deleted side wins;
/// still tied → a content-based deterministic, order-independent tiebreak.
fn pick<'a, T: serde::Serialize>(
    local: &'a T,
    remote: &'a T,
    local_updated: i64,
    remote_updated: i64,
    local_deleted: bool,
    remote_deleted: bool,
) -> &'a T {
    if local_updated > remote_updated {
        return local;
    }
    if remote_updated > local_updated {
        return remote;
    }
    // Tie on updated_at → the tombstoned side wins.
    if local_deleted != remote_deleted {
        return if local_deleted { local } else { remote };
    }
    // Fully tied → deterministic, commutative content comparison.
    let ls = serde_json::to_string(local).unwrap_or_default();
    let rs = serde_json::to_string(remote).unwrap_or_default();
    if rs > ls {
        remote
    } else {
        local
    }
}

// ---------------------------------------------------------------------------
// WebDAV backend
// ---------------------------------------------------------------------------

#[cfg(feature = "webdav")]
pub mod webdav {
    use super::{RemoteBlob, SyncBackend, SyncError};
    use base64::engine::general_purpose::STANDARD as B64;
    use base64::Engine;

    /// Single-file WebDAV backend (ETag / If-Match optimistic concurrency, Basic auth).
    pub struct WebDavBackend {
        url: String,
        username: String,
        password: String,
    }

    /// Build an HTTP Basic `Authorization` header value.
    pub(crate) fn basic_auth_header(username: &str, password: &str) -> String {
        format!("Basic {}", B64.encode(format!("{username}:{password}")))
    }

    impl WebDavBackend {
        /// `url` points at the vault file itself, e.g.
        /// https://host/remote.php/dav/files/me/otpeek-vault.otpvault
        pub fn new(url: String, username: String, password: String) -> Self {
            Self {
                url,
                username,
                password,
            }
        }

        fn auth(&self) -> String {
            basic_auth_header(&self.username, &self.password)
        }
    }

    impl SyncBackend for WebDavBackend {
        fn fetch(&self) -> Result<Option<RemoteBlob>, SyncError> {
            use std::io::Read;
            let resp = ureq::get(&self.url)
                .set("Authorization", &self.auth())
                .call();
            match resp {
                Ok(r) => {
                    let etag = r.header("ETag").map(|s| s.to_string());
                    let mut data = Vec::new();
                    r.into_reader()
                        .read_to_end(&mut data)
                        .map_err(|e| SyncError::Network(e.to_string()))?;
                    Ok(Some(RemoteBlob { data, etag }))
                }
                Err(ureq::Error::Status(404, _)) | Err(ureq::Error::Status(410, _)) => Ok(None),
                Err(ureq::Error::Status(401, _)) | Err(ureq::Error::Status(403, _)) => {
                    Err(SyncError::Auth("unauthorized".into()))
                }
                Err(ureq::Error::Status(code, _)) => {
                    Err(SyncError::Backend(format!("http {code}")))
                }
                Err(ureq::Error::Transport(t)) => Err(SyncError::Network(t.to_string())),
            }
        }

        fn store(&self, data: Vec<u8>, if_match: Option<String>) -> Result<String, SyncError> {
            let mut req = ureq::put(&self.url).set("Authorization", &self.auth());
            match &if_match {
                Some(etag) => req = req.set("If-Match", etag),
                None => req = req.set("If-None-Match", "*"),
            }
            match req.send_bytes(&data) {
                Ok(r) => Ok(r.header("ETag").map(|s| s.to_string()).unwrap_or_default()),
                Err(ureq::Error::Status(412, _)) => Err(SyncError::Conflict),
                Err(ureq::Error::Status(401, _)) | Err(ureq::Error::Status(403, _)) => {
                    Err(SyncError::Auth("unauthorized".into()))
                }
                Err(ureq::Error::Status(code, _)) => {
                    Err(SyncError::Backend(format!("http {code}")))
                }
                Err(ureq::Error::Transport(t)) => Err(SyncError::Network(t.to_string())),
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn basic_auth_is_base64_user_colon_pass() {
            // "me:secret" => "bWU6c2VjcmV0"
            assert_eq!(basic_auth_header("me", "secret"), "Basic bWU6c2VjcmV0");
        }
    }
}
