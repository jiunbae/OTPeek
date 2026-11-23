//! Merge-rule table tests, determinism check, and engine tests against an
//! in-memory SyncBackend.

use std::sync::Mutex;

use otpeek_core::{HashAlgorithm, OtpAccount, OtpFolder, OtpType};
use otpeek_sync::{RemoteBlob, SyncBackend, SyncEngine, SyncError};
use otpeek_vault::{Vault, VaultError, VaultPayload};

const NOW: i64 = 1_730_000_000_000;

// ---------------------------------------------------------------------------
// Builders
// ---------------------------------------------------------------------------

fn acct(id: &str, updated_at: i64, deleted: Option<i64>, counter: u64) -> OtpAccount {
    OtpAccount {
        id: id.into(),
        otp_type: if counter > 0 {
            OtpType::Hotp
        } else {
            OtpType::Totp
        },
        secret: "JBSWY3DPEHPK3PXP".into(),
        issuer: Some("Issuer".into()),
        account_name: format!("acct-{id}"),
        algorithm: HashAlgorithm::Sha1,
        digits: 6,
        period: 30,
        counter,
        folder_id: None,
        is_favorite: false,
        sort_order: 0,
        icon: None,
        color: None,
        created_at: 0,
        updated_at,
        deleted_at: deleted,
    }
}

fn folder(id: &str, updated_at: i64, deleted: Option<i64>, name: &str) -> OtpFolder {
    OtpFolder {
        id: id.into(),
        name: name.into(),
        icon: None,
        color: None,
        sort_order: 0,
        created_at: 0,
        updated_at,
        deleted_at: deleted,
    }
}

fn payload(accounts: Vec<OtpAccount>, folders: Vec<OtpFolder>) -> VaultPayload {
    VaultPayload { accounts, folders }
}

// ---------------------------------------------------------------------------
// Merge rules
// ---------------------------------------------------------------------------

#[test]
fn present_on_one_side_only_is_kept() {
    let local = payload(vec![acct("a", 10, None, 0)], vec![]);
    let remote = payload(vec![acct("b", 10, None, 0)], vec![]);
    let (merged, changes) = SyncEngine::merge(&local, &remote);
    let ids: Vec<&str> = merged.accounts.iter().map(|a| a.id.as_str()).collect();
    assert_eq!(ids, vec!["a", "b"]);
    assert_eq!(changes, 1, "remote-only 'b' differs from local");
}

#[test]
fn lww_greater_updated_at_wins() {
    let local = payload(vec![acct("a", 10, None, 0)], vec![]);
    let mut newer = acct("a", 20, None, 0);
    newer.account_name = "remote-wins".into();
    let remote = payload(vec![newer], vec![]);

    let (merged, changes) = SyncEngine::merge(&local, &remote);
    assert_eq!(merged.accounts[0].account_name, "remote-wins");
    assert_eq!(changes, 1);

    // And the reverse: local newer wins.
    let (merged2, changes2) = SyncEngine::merge(&remote, &local);
    assert_eq!(merged2.accounts[0].account_name, "remote-wins");
    assert_eq!(changes2, 0, "local (remote payload) already newest");
}

#[test]
fn tie_deleted_side_wins() {
    let live = acct("a", 10, None, 0);
    let tomb = acct("a", 10, Some(10), 0);
    let local = payload(vec![live.clone()], vec![]);
    let remote = payload(vec![tomb.clone()], vec![]);

    let (merged, _) = SyncEngine::merge(&local, &remote);
    assert!(
        merged.accounts[0].deleted_at.is_some(),
        "tombstone wins tie"
    );

    // Symmetric.
    let (merged2, _) = SyncEngine::merge(&remote, &local);
    assert!(merged2.accounts[0].deleted_at.is_some());
}

#[test]
fn hotp_counter_is_max_regardless_of_lww() {
    // Local wins LWW (newer) but remote has the higher counter.
    let mut local_acct = acct("a", 20, None, 5);
    local_acct.account_name = "local-wins".into();
    let remote_acct = acct("a", 10, None, 42);

    let local = payload(vec![local_acct], vec![]);
    let remote = payload(vec![remote_acct], vec![]);

    let (merged, changes) = SyncEngine::merge(&local, &remote);
    assert_eq!(merged.accounts[0].account_name, "local-wins");
    assert_eq!(merged.accounts[0].counter, 42, "counter never regresses");
    assert_eq!(changes, 1, "counter bump means merged differs from local");
}

#[test]
fn tombstone_propagates() {
    let local = payload(vec![acct("a", 10, None, 0)], vec![]);
    let remote = payload(vec![acct("a", 20, Some(20), 0)], vec![]);
    let (merged, _) = SyncEngine::merge(&local, &remote);
    assert!(merged.accounts[0].deleted_at.is_some());
}

#[test]
fn folders_merge_independently() {
    let local = payload(vec![], vec![folder("f", 10, None, "old")]);
    let remote = payload(vec![], vec![folder("f", 20, None, "new")]);
    let (merged, changes) = SyncEngine::merge(&local, &remote);
    assert_eq!(merged.folders[0].name, "new");
    assert_eq!(changes, 1);
}

#[test]
fn merge_is_deterministic_and_commutative() {
    // Full tie (same updated_at, both live) with differing content.
    let mut a = acct("x", 10, None, 0);
    a.account_name = "alpha".into();
    let mut b = acct("x", 10, None, 0);
    b.account_name = "bravo".into();

    let local = payload(
        vec![a.clone(), acct("y", 5, None, 0)],
        vec![folder("f1", 10, None, "L"), folder("f2", 3, None, "shared")],
    );
    let remote = payload(
        vec![b.clone(), acct("z", 7, None, 0)],
        vec![folder("f2", 3, None, "shared"), folder("f3", 9, None, "R")],
    );

    let (ab, _) = SyncEngine::merge(&local, &remote);
    let (ba, _) = SyncEngine::merge(&remote, &local);
    assert_eq!(ab, ba, "merge must be commutative in content");

    // Stable across repeated calls.
    let (ab2, _) = SyncEngine::merge(&local, &remote);
    assert_eq!(ab, ab2);
}

#[test]
fn merged_changes_counts_new_and_modified() {
    let local = payload(vec![acct("a", 10, None, 0)], vec![]);
    let remote = payload(
        vec![acct("a", 20, None, 0), acct("b", 5, None, 0)],
        vec![folder("f", 1, None, "n")],
    );
    let (_, changes) = SyncEngine::merge(&local, &remote);
    // 'a' modified (remote newer) + 'b' new account + 'f' new folder = 3.
    assert_eq!(changes, 3);
}

// ---------------------------------------------------------------------------
// In-memory backend + engine
// ---------------------------------------------------------------------------

struct InMemoryBackend {
    state: Mutex<State>,
}

struct State {
    blob: Option<(Vec<u8>, String)>,
    next_etag: u64,
    inject_conflicts: u32,
    fetches: u32,
    stores: u32,
}

impl InMemoryBackend {
    fn empty() -> Self {
        Self {
            state: Mutex::new(State {
                blob: None,
                next_etag: 1,
                inject_conflicts: 0,
                fetches: 0,
                stores: 0,
            }),
        }
    }

    fn with_blob(data: Vec<u8>) -> Self {
        let b = Self::empty();
        {
            let mut s = b.state.lock().unwrap();
            s.blob = Some((data, "etag-0".into()));
        }
        b
    }
}

impl SyncBackend for InMemoryBackend {
    fn fetch(&self) -> Result<Option<RemoteBlob>, SyncError> {
        let mut s = self.state.lock().unwrap();
        s.fetches += 1;
        Ok(s.blob.as_ref().map(|(data, etag)| RemoteBlob {
            data: data.clone(),
            etag: Some(etag.clone()),
        }))
    }

    fn store(&self, data: Vec<u8>, if_match: Option<String>) -> Result<String, SyncError> {
        let mut s = self.state.lock().unwrap();
        s.stores += 1;
        if s.inject_conflicts > 0 {
            s.inject_conflicts -= 1;
            return Err(SyncError::Conflict);
        }
        match (&if_match, &s.blob) {
            (Some(etag), Some((_, cur))) if etag == cur => {}
            (Some(_), Some(_)) => return Err(SyncError::Conflict),
            (Some(_), None) => return Err(SyncError::Conflict),
            (None, Some(_)) => return Err(SyncError::Conflict),
            (None, None) => {}
        }
        let etag = format!("etag-{}", s.next_etag);
        s.next_etag += 1;
        s.blob = Some((data, etag.clone()));
        Ok(etag)
    }
}

fn vault_with(accounts: Vec<OtpAccount>) -> Vault {
    let mut v = Vault::create("test-password-123").expect("create");
    v.payload_mut().accounts = accounts;
    v
}

/// Build an independent vault that shares `local`'s VMK (so its serialized blob
/// decrypts under the local key). Mutates local generation.
fn remote_sharing_key(local: &mut Vault) -> Vault {
    let vmk = local.vmk();
    let bytes = local.to_bytes(NOW).expect("serialize local");
    Vault::open_with_key(&bytes, &vmk).expect("reopen shared-key vault")
}

fn remote_blob_with(local: &mut Vault, accounts: Vec<OtpAccount>) -> Vec<u8> {
    let mut remote = remote_sharing_key(local);
    remote.payload_mut().accounts = accounts;
    remote.to_bytes(NOW).expect("serialize remote")
}

#[test]
fn first_push_when_remote_empty() {
    let mut local = vault_with(vec![acct("a", 10, None, 0)]);
    let backend = InMemoryBackend::empty();
    let outcome = SyncEngine::sync(&mut local, &backend, NOW).expect("sync");
    assert!(outcome.pushed);
    assert!(!outcome.pulled);
    assert_eq!(outcome.merged_changes, 0);
    assert!(backend.state.lock().unwrap().blob.is_some());
}

#[test]
fn pull_only_gains_remote_entities() {
    let mut local = vault_with(vec![]);
    let blob = remote_blob_with(&mut local, vec![acct("r", 10, None, 0)]);
    let backend = InMemoryBackend::with_blob(blob);

    let outcome = SyncEngine::sync(&mut local, &backend, NOW).expect("sync");
    assert!(outcome.pulled, "local changed due to remote");
    assert!(outcome.pushed);
    assert_eq!(outcome.merged_changes, 1);
    let ids: Vec<&str> = local
        .payload()
        .accounts
        .iter()
        .map(|a| a.id.as_str())
        .collect();
    assert_eq!(ids, vec!["r"]);
}

#[test]
fn merge_push_combines_both_sides() {
    let mut local = vault_with(vec![acct("a", 30, None, 0)]);
    // Remote has an older 'a' plus a new 'b'.
    let blob = remote_blob_with(
        &mut local,
        vec![acct("a", 10, None, 0), acct("b", 20, None, 0)],
    );
    let backend = InMemoryBackend::with_blob(blob);

    let outcome = SyncEngine::sync(&mut local, &backend, NOW).expect("sync");
    assert!(outcome.pushed);
    assert!(outcome.pulled, "gained 'b'");
    assert_eq!(outcome.merged_changes, 1, "only 'b' is new vs local");
    let mut ids: Vec<&str> = local
        .payload()
        .accounts
        .iter()
        .map(|a| a.id.as_str())
        .collect();
    ids.sort_unstable();
    assert_eq!(ids, vec!["a", "b"]);
}

#[test]
fn etag_conflict_retries_then_succeeds() {
    let mut local = vault_with(vec![acct("a", 30, None, 0)]);
    let blob = remote_blob_with(&mut local, vec![acct("r", 10, None, 0)]);
    let backend = InMemoryBackend::with_blob(blob);
    backend.state.lock().unwrap().inject_conflicts = 1; // first store conflicts
    let generation = local.generation();

    let outcome = SyncEngine::sync(&mut local, &backend, NOW).expect("sync");
    assert!(outcome.pushed);
    assert!(outcome.pulled);
    assert_eq!(outcome.merged_changes, 1);
    assert_eq!(local.generation(), generation + 1);
    let s = backend.state.lock().unwrap();
    assert_eq!(s.stores, 2, "one conflict + one success");
    assert!(s.fetches >= 2, "refetched after conflict");
}

#[test]
fn etag_conflict_exhausts_retries() {
    let mut local = vault_with(vec![acct("a", 30, None, 0)]);
    let blob = remote_blob_with(&mut local, vec![acct("r", 10, None, 0)]);
    let backend = InMemoryBackend::with_blob(blob);
    backend.state.lock().unwrap().inject_conflicts = 99; // always conflict
    let original = local.payload().clone();
    let generation = local.generation();

    match SyncEngine::sync(&mut local, &backend, NOW) {
        Err(SyncError::Conflict) => {}
        other => panic!("expected Conflict after retries, got {other:?}"),
    }
    assert_eq!(backend.state.lock().unwrap().stores, 3, "max 3 attempts");
    assert_eq!(local.generation(), generation);
    assert_eq!(local.payload(), &original);
}

#[test]
fn stale_device_cannot_replace_new_password_with_a_newer_payload_save() {
    let mut stale = vault_with(vec![]);
    let mut changed = remote_sharing_key(&mut stale);
    changed
        .change_password("test-password-123", "replacement password")
        .unwrap();
    let backend = InMemoryBackend::with_blob(changed.to_bytes(NOW).unwrap());
    stale
        .payload_mut()
        .accounts
        .push(acct("unsynced", 30, None, 0));
    stale.to_bytes(NOW + 10).unwrap();
    stale.to_bytes(NOW + 20).unwrap();

    let result = SyncEngine::sync(&mut stale, &backend, NOW + 30).unwrap();
    assert!(result.pulled);
    assert_eq!(result.merged_changes, 0);
    let local_bytes = stale.to_bytes(NOW + 40).unwrap();
    assert!(Vault::open_with_password(&local_bytes, "replacement password").is_ok());
    let stored = backend.fetch().unwrap().unwrap();
    let remote = Vault::open_with_password(&stored.data, "replacement password").unwrap();
    assert_eq!(remote.payload().accounts[0].id, "unsynced");
    assert!(matches!(
        Vault::open_with_password(&stored.data, "test-password-123"),
        Err(VaultError::WrongPassword)
    ));
}

#[test]
fn stale_device_does_not_resurrect_old_tombstones() {
    let mut stale = vault_with(vec![acct("old", 10, None, 0)]);
    stale
        .payload_mut()
        .folders
        .push(folder("old-folder", 10, None, "old"));
    let mut deleted = remote_sharing_key(&mut stale);
    *deleted.payload_mut() = payload(
        vec![acct("old", 20, Some(20), 0)],
        vec![folder("old-folder", 20, Some(20), "old")],
    );
    let backend = InMemoryBackend::with_blob(deleted.to_bytes(NOW).unwrap());

    let result = SyncEngine::sync(&mut stale, &backend, NOW).unwrap();
    assert_eq!(result.merged_changes, 2);
    let stored = backend.fetch().unwrap().unwrap();
    let reopened = stale.open_peer(&stored.data).unwrap();
    assert_eq!(reopened.payload().accounts[0].deleted_at, Some(20));
    assert!(reopened.payload().accounts[0].secret.is_empty());
    assert_eq!(reopened.payload().folders[0].deleted_at, Some(20));
    assert!(reopened.payload().folders[0].name.is_empty());
}

#[test]
fn remote_without_etag_is_not_overwritten() {
    let mut local = vault_with(vec![acct("a", 30, None, 0)]);
    let backend = InMemoryBackend::with_blob(remote_blob_with(&mut local, vec![]));
    backend
        .state
        .lock()
        .unwrap()
        .blob
        .as_mut()
        .unwrap()
        .1
        .clear();
    let generation = local.generation();
    assert!(matches!(
        SyncEngine::sync(&mut local, &backend, NOW),
        Err(SyncError::Backend(msg)) if msg.contains("ETag")
    ));
    assert_eq!(backend.state.lock().unwrap().stores, 0);
    assert_eq!(local.generation(), generation);
}

#[test]
fn wrong_key_when_remote_encrypted_with_other_vmk() {
    let mut local = vault_with(vec![acct("a", 10, None, 0)]);
    // Foreign vault → different VMK.
    let mut foreign = Vault::create("other-password").expect("create foreign");
    foreign.payload_mut().accounts.push(acct("x", 10, None, 0));
    let foreign_blob = foreign.to_bytes(NOW).expect("serialize foreign");
    let backend = InMemoryBackend::with_blob(foreign_blob);

    match SyncEngine::sync(&mut local, &backend, NOW) {
        Err(SyncError::Vault(VaultError::WrongKey)) => {}
        other => panic!("expected Vault(WrongKey), got {other:?}"),
    }
}
