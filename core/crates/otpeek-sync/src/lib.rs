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
    /// Fetch, decrypt and merge into a staged vault, then conditionally store it.
    /// Publish the staged result to `local` only after a successful store.
    pub fn sync(
        local: &mut Vault,
        backend: &dyn SyncBackend,
        now_ms: i64,
    ) -> Result<SyncOutcome, SyncError> {
        for _ in 0..MAX_ATTEMPTS {
            let mut candidate = local.clone();
            let (if_match, pulled, merged_changes) = match backend.fetch()? {
                None => (None, false, 0),
                Some(blob) => {
                    let etag = blob.etag.filter(|tag| !tag.is_empty()).ok_or_else(|| {
                        SyncError::Backend("remote vault has no ETag for conditional update".into())
                    })?;
                    let remote = local.open_peer(&blob.data)?;
                    let (merged, changes) = Self::merge(local.payload(), remote.payload());
                    *candidate.payload_mut() = merged;
                    let rewrapped = candidate.merge_password_wrap(&remote)?;
                    (Some(etag), rewrapped || changes > 0, changes)
                }
            };
            let bytes = candidate.to_bytes(now_ms)?;
            match backend.store(bytes, if_match) {
                Ok(_) => {
                    *local = candidate;
                    return Ok(SyncOutcome {
                        pushed: true,
                        pulled,
                        merged_changes,
                    });
                }
                Err(SyncError::Conflict) => continue,
                Err(e) => return Err(e),
            }
        }
        Err(SyncError::Conflict)
    }

    /// Pure merge per docs/ARCHITECTURE.md §6.2 (LWW by updated_at, tombstone
    /// tiebreak, HOTP counter = max). Returns (merged, changed-entity count).
    pub fn merge(local: &VaultPayload, remote: &VaultPayload) -> (VaultPayload, u32) {
        let (accounts, acct_changes) = merge_accounts(&local.accounts, &remote.accounts);
        let (folders, folder_changes) = merge_folders(&local.folders, &remote.folders);
        let mut merged = VaultPayload { accounts, folders };
        merged.compact_tombstones();
        (merged, acct_changes + folder_changes)
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
    use std::time::Duration;

    /// Single-file WebDAV backend (ETag / If-Match optimistic concurrency, Basic auth).
    pub struct WebDavBackend {
        agent: ureq::Agent,
        url: String,
        username: String,
        password: String,
    }

    /// Build an HTTP Basic `Authorization` header value.
    pub(crate) fn basic_auth_header(username: &str, password: &str) -> String {
        format!("Basic {}", B64.encode(format!("{username}:{password}")))
    }

    fn is_strong_etag(tag: &str) -> bool {
        tag.strip_prefix('"')
            .and_then(|tag| tag.strip_suffix('"'))
            .is_some_and(|opaque| {
                opaque
                    .bytes()
                    .all(|byte| byte == 0x21 || (0x23..=0x7e).contains(&byte) || byte >= 0x80)
            })
    }

    impl WebDavBackend {
        /// `url` points at the vault file itself, e.g.
        /// https://host/remote.php/dav/files/me/otpeek-vault.otpvault
        pub fn new(url: String, username: String, password: String) -> Self {
            Self {
                agent: ureq::AgentBuilder::new()
                    .https_only(true)
                    .redirects(0)
                    .timeout_connect(Duration::from_secs(10))
                    .timeout(Duration::from_secs(30))
                    .build(),
                url,
                username,
                password,
            }
        }

        /// Validate the endpoint before prompting for or sending credentials.
        pub fn validate_url(url: &str) -> Result<(), SyncError> {
            Self::validate_request_url(&ureq::get(url))
        }

        fn validate_request_url(request: &ureq::Request) -> Result<(), SyncError> {
            let parsed = request
                .request_url()
                .map_err(|_| SyncError::Backend("invalid WebDAV URL".into()))?;
            let url = parsed.as_url();
            if url.scheme() != "https" || !url.username().is_empty() || url.password().is_some() {
                return Err(SyncError::Backend(
                    "WebDAV requires an HTTPS URL without embedded credentials".into(),
                ));
            }
            if url.fragment().is_some() {
                return Err(SyncError::Backend(
                    "WebDAV URL cannot contain a fragment".into(),
                ));
            }
            Ok(())
        }

        fn auth(&self) -> String {
            basic_auth_header(&self.username, &self.password)
        }
    }

    impl SyncBackend for WebDavBackend {
        fn fetch(&self) -> Result<Option<RemoteBlob>, SyncError> {
            let request = self.agent.get(&self.url);
            Self::validate_request_url(&request)?;
            let resp = request.set("Authorization", &self.auth()).call();
            match resp {
                Ok(r) if r.status() == 200 => {
                    let etag = r.header("ETag").map(|s| s.to_string());
                    let data =
                        otpeek_vault::read_vault_reader(r.into_reader()).map_err(|e| match e {
                            otpeek_vault::VaultError::Io(msg) => SyncError::Network(msg),
                            other => SyncError::Vault(other),
                        })?;
                    Ok(Some(RemoteBlob { data, etag }))
                }
                Ok(r) => Err(SyncError::Backend(format!("http {}", r.status()))),
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
            let request = self.agent.put(&self.url);
            Self::validate_request_url(&request)?;
            if data.len() > otpeek_vault::MAX_VAULT_BYTES {
                return Err(SyncError::Backend("vault exceeds the size limit".into()));
            }
            let mut req = request.set("Authorization", &self.auth());
            match &if_match {
                Some(etag) if is_strong_etag(etag) => {
                    req = req.set("If-Match", etag);
                }
                Some(_) => {
                    return Err(SyncError::Backend(
                        "WebDAV requires a strong ETag for conditional update".into(),
                    ))
                }
                None => req = req.set("If-None-Match", "*"),
            }
            match req.send_bytes(&data) {
                Ok(r) if matches!(r.status(), 200 | 201 | 204) => {
                    Ok(r.header("ETag").map(|s| s.to_string()).unwrap_or_default())
                }
                Ok(r) => Err(SyncError::Backend(format!("http {}", r.status()))),
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

        #[test]
        fn cleartext_requests_are_rejected() {
            let url = "http://example.invalid/vault".to_string();
            assert!(WebDavBackend::validate_url(&url).is_err());
            let backend = WebDavBackend::new(url, "user".into(), "password".into());
            assert!(matches!(backend.fetch(), Err(SyncError::Backend(_))));
            assert!(matches!(
                backend.store(vec![], None),
                Err(SyncError::Backend(_))
            ));
            assert!(WebDavBackend::validate_url("https://example.invalid/vault").is_ok());
            assert!(WebDavBackend::validate_url("https://user@example.invalid/vault").is_err());
            assert!(WebDavBackend::validate_url("https://example.invalid/vault#fragment").is_err());
        }

        #[test]
        fn conditional_update_requires_a_single_strong_etag() {
            assert!(is_strong_etag(r#""revision-1""#));
            assert!(!is_strong_etag(r#"W/"revision-1""#));
            assert!(!is_strong_etag(""));
        }
    }
}
