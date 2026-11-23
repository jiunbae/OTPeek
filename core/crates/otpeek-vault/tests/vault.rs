//! Integration tests for vault round-trips, tombstones, file transactions,
//! v1 import and a committed-fixture format-stability guard.

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use otpeek_core::{HashAlgorithm, OtpAccount, OtpType};
use otpeek_vault::{import_backup_v1, Vault, VaultError};

const NOW: i64 = 1_730_000_000_000;
const NINETY_DAYS_MS: i64 = 90 * 24 * 60 * 60 * 1000;

fn sample_account(id: &str) -> OtpAccount {
    OtpAccount {
        id: id.to_string(),
        otp_type: OtpType::Totp,
        secret: "JBSWY3DPEHPK3PXP".into(),
        issuer: Some("GitHub".into()),
        account_name: "octocat".into(),
        algorithm: HashAlgorithm::Sha1,
        digits: 6,
        period: 30,
        counter: 0,
        folder_id: None,
        is_favorite: false,
        sort_order: 0,
        icon: None,
        color: None,
        created_at: NOW,
        updated_at: NOW,
        deleted_at: None,
    }
}

fn new_vault_with_account() -> (Vault, Vec<u8>) {
    let mut v = Vault::create("test-password-123").expect("create");
    v.payload_mut().accounts.push(sample_account("acct-1"));
    let vmk = v.vmk();
    (v, vmk)
}

#[test]
fn round_trip_key_path() {
    let (mut v, vmk) = new_vault_with_account();
    let bytes = v.to_bytes(NOW).expect("to_bytes");

    let opened = Vault::open_with_key(&bytes, &vmk).expect("open_with_key");
    assert_eq!(opened.payload().accounts.len(), 1);
    assert_eq!(opened.payload().accounts[0].id, "acct-1");
    assert_eq!(opened.generation(), 1);
}

#[test]
fn round_trip_password_path() {
    let (mut v, _vmk) = new_vault_with_account();
    let bytes = v.to_bytes(NOW).expect("to_bytes");

    let opened = Vault::open_with_password(&bytes, "test-password-123").expect("open pw");
    assert_eq!(opened.payload().accounts.len(), 1);
    assert_eq!(opened.payload().accounts[0].secret, "JBSWY3DPEHPK3PXP");
}

#[test]
fn fresh_nonce_and_generation_each_save() {
    let (mut v, _vmk) = new_vault_with_account();
    let a = v.to_bytes(NOW).expect("save 1");
    let b = v.to_bytes(NOW).expect("save 2");
    assert_ne!(a, b, "vaultNonce must change every save");
    assert_eq!(v.generation(), 2);
}

#[test]
fn wrong_password_errors() {
    let (mut v, _vmk) = new_vault_with_account();
    let bytes = v.to_bytes(NOW).expect("to_bytes");
    match Vault::open_with_password(&bytes, "not-the-password") {
        Err(VaultError::WrongPassword) => {}
        Ok(_) => panic!("unexpectedly succeeded, expected WrongPassword"),
        Err(other) => panic!("expected WrongPassword, got {other:?}"),
    }
}

#[test]
fn wrong_key_errors() {
    let (mut v, _vmk) = new_vault_with_account();
    let bytes = v.to_bytes(NOW).expect("to_bytes");
    let bad = vec![7u8; 32];
    match Vault::open_with_key(&bytes, &bad) {
        Err(VaultError::WrongKey) => {}
        Ok(_) => panic!("unexpectedly succeeded, expected WrongKey"),
        Err(other) => panic!("expected WrongKey, got {other:?}"),
    }
}

#[test]
fn wrong_key_length_errors() {
    let (mut v, _vmk) = new_vault_with_account();
    let bytes = v.to_bytes(NOW).expect("to_bytes");
    match Vault::open_with_key(&bytes, &[1, 2, 3]) {
        Err(VaultError::WrongKey) => {}
        Ok(_) => panic!("unexpectedly succeeded, expected WrongKey"),
        Err(other) => panic!("expected WrongKey, got {other:?}"),
    }
}

#[test]
fn bad_magic_is_corrupt() {
    let (mut v, vmk) = new_vault_with_account();
    let mut bytes = v.to_bytes(NOW).expect("to_bytes");
    bytes[0] = b'X';
    match Vault::open_with_key(&bytes, &vmk) {
        Err(VaultError::Corrupt(_)) => {}
        Ok(_) => panic!("unexpectedly succeeded, expected Corrupt"),
        Err(other) => panic!("expected Corrupt, got {other:?}"),
    }
}

#[test]
fn bad_version_is_corrupt() {
    let (mut v, vmk) = new_vault_with_account();
    let mut bytes = v.to_bytes(NOW).expect("to_bytes");
    bytes[8] = 9; // version LE first byte
    match Vault::open_with_key(&bytes, &vmk) {
        Err(VaultError::Corrupt(_)) => {}
        Ok(_) => panic!("unexpectedly succeeded, expected Corrupt"),
        Err(other) => panic!("expected Corrupt, got {other:?}"),
    }
}

#[test]
fn truncated_is_corrupt() {
    let (mut v, vmk) = new_vault_with_account();
    let bytes = v.to_bytes(NOW).expect("to_bytes");
    let truncated = &bytes[..10];
    match Vault::open_with_key(truncated, &vmk) {
        Err(VaultError::Corrupt(_)) => {}
        Ok(_) => panic!("unexpectedly succeeded, expected Corrupt"),
        Err(other) => panic!("expected Corrupt, got {other:?}"),
    }
}

#[test]
fn header_length_beyond_file_is_corrupt() {
    let (mut v, vmk) = new_vault_with_account();
    let mut bytes = v.to_bytes(NOW).expect("to_bytes");
    // Set header length to something enormous.
    bytes[12] = 0xff;
    bytes[13] = 0xff;
    bytes[14] = 0xff;
    bytes[15] = 0x7f;
    match Vault::open_with_key(&bytes, &vmk) {
        Err(VaultError::Corrupt(_)) => {}
        Ok(_) => panic!("unexpectedly succeeded, expected Corrupt"),
        Err(other) => panic!("expected Corrupt, got {other:?}"),
    }
}

#[test]
fn aad_tamper_detected() {
    // Flipping a byte inside the header region (still structurally valid) must
    // break AES-GCM authentication of the payload (AAD covers the header).
    let (mut v, vmk) = new_vault_with_account();
    let mut bytes = v.to_bytes(NOW).expect("to_bytes");
    // The salt base64 lives inside the header JSON; flip a byte well inside it.
    let idx = 40; // within header bytes (header starts at offset 16)
    bytes[idx] ^= 0x01;
    // Must be detected: either the header no longer parses (Corrupt) or GCM
    // authentication of the payload fails because the AAD changed (WrongKey).
    match Vault::open_with_key(&bytes, &vmk) {
        Err(VaultError::WrongKey) | Err(VaultError::Corrupt(_)) => {}
        Ok(_) => panic!("AAD tamper went undetected"),
        Err(other) => panic!("unexpected error on AAD tamper: {other:?}"),
    }
}

#[test]
fn ciphertext_tamper_detected() {
    let (mut v, vmk) = new_vault_with_account();
    let mut bytes = v.to_bytes(NOW).expect("to_bytes");
    let last = bytes.len() - 1;
    bytes[last] ^= 0x01;
    match Vault::open_with_key(&bytes, &vmk) {
        Err(VaultError::WrongKey) => {}
        Ok(_) => panic!("unexpectedly succeeded, expected WrongKey"),
        Err(other) => panic!("expected WrongKey on ciphertext tamper, got {other:?}"),
    }
}

#[test]
fn change_password_rewraps() {
    let (mut v, vmk) = new_vault_with_account();
    v.change_password("test-password-123", "new-password-456")
        .expect("change_password");
    let bytes = v.to_bytes(NOW).expect("to_bytes");

    // Old password no longer works.
    assert!(matches!(
        Vault::open_with_password(&bytes, "test-password-123"),
        Err(VaultError::WrongPassword)
    ));
    // New password works and VMK is unchanged (key path still works).
    let opened = Vault::open_with_password(&bytes, "new-password-456").expect("open new pw");
    assert_eq!(opened.vmk(), vmk);
}

#[test]
fn change_password_wrong_old_errors() {
    let mut v = Vault::create("test-password-123").expect("create");
    match v.change_password("wrong-old", "whatever") {
        Err(VaultError::WrongPassword) => {}
        Ok(_) => panic!("unexpectedly succeeded, expected WrongPassword"),
        Err(other) => panic!("expected WrongPassword, got {other:?}"),
    }
}

#[test]
fn old_tombstones_survive_serialization() {
    let mut v = Vault::create("test-password-123").expect("create");

    let mut live = sample_account("live");
    live.deleted_at = None;

    let mut at_boundary = sample_account("boundary");
    at_boundary.deleted_at = Some(NOW - NINETY_DAYS_MS);

    let mut just_old = sample_account("old");
    just_old.deleted_at = Some(NOW - NINETY_DAYS_MS - 1);
    just_old.counter = 42;

    v.payload_mut().accounts.push(live);
    v.payload_mut().accounts.push(at_boundary);
    v.payload_mut().accounts.push(just_old);

    let bytes = v.to_bytes(NOW).expect("to_bytes");
    let opened = Vault::open_with_password(&bytes, "test-password-123").expect("open");
    let ids: Vec<&str> = opened
        .payload()
        .accounts
        .iter()
        .map(|a| a.id.as_str())
        .collect();
    assert!(ids.contains(&"live"));
    assert!(ids.contains(&"boundary"), "boundary (exactly 90d) is kept");
    assert!(ids.contains(&"old"), "older deletions still replicate");
    assert_eq!(opened.payload().accounts.len(), 3);
    let old = &opened.payload().accounts[2];
    assert_eq!(old.counter, 42);
    assert_eq!(old.updated_at, NOW);
    assert_eq!(old.deleted_at, Some(NOW - NINETY_DAYS_MS - 1));
    assert!(old.secret.is_empty());
    assert!(old.account_name.is_empty());
    assert!(old.issuer.is_none());

    // Inspect the wire data independently of the reader's legacy compaction.
    let header_end = 16 + u32::from_le_bytes(bytes[12..16].try_into().unwrap()) as usize;
    let header: serde_json::Value = serde_json::from_slice(&bytes[16..header_end]).unwrap();
    let nonce = B64.decode(header["vaultNonce"].as_str().unwrap()).unwrap();
    let wire = Aes256Gcm::new_from_slice(&v.vmk())
        .unwrap()
        .decrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: &bytes[header_end..],
                aad: &bytes[..header_end],
            },
        )
        .unwrap();
    let wire: serde_json::Value = serde_json::from_slice(&wire).unwrap();
    assert_eq!(wire["accounts"][2]["secret"], "");
    assert_eq!(wire["accounts"][2]["accountName"], "");
}

#[test]
fn validates_v2_kdf_before_derivation() {
    let data = include_bytes!("fixtures/vault-v2.otpvault");
    let header_len = u32::from_le_bytes(data[12..16].try_into().unwrap()) as usize;
    let mut header: serde_json::Value = serde_json::from_slice(&data[16..16 + header_len]).unwrap();
    header["kdf"]["mKib"] = 32768.into();
    let header = serde_json::to_vec(&header).unwrap();
    let mut modified = data[..12].to_vec();
    modified.extend_from_slice(&(header.len() as u32).to_le_bytes());
    modified.extend_from_slice(&header);
    modified.extend_from_slice(&data[16 + header_len..]);
    assert!(matches!(
        Vault::open_with_password(&modified, "test-password-123"),
        Err(VaultError::Corrupt(msg)) if msg.contains("KDF")
    ));
}

#[test]
fn limits_streamed_vault_bytes() {
    use std::io::{self, Read};
    let reader = io::repeat(0).take(otpeek_vault::MAX_VAULT_BYTES as u64 + 2);
    assert!(matches!(
        otpeek_vault::read_vault_reader(reader),
        Err(VaultError::Corrupt(msg)) if msg.contains("size limit")
    ));
}

// -- v1 legacy import ------------------------------------------------------

/// Encrypt a v1 .otpbackup with the documented parameters (PBKDF2-SHA256 100k,
/// AES-256-GCM), producing the on-disk byte layout.
fn make_v1_backup(payload_json: &str, password: &str) -> Vec<u8> {
    use rand::RngCore;
    let mut salt = [0u8; 32];
    let mut nonce = [0u8; 12];
    rand::rngs::OsRng.fill_bytes(&mut salt);
    rand::rngs::OsRng.fill_bytes(&mut nonce);

    let key = pbkdf2::pbkdf2_hmac_array::<sha2::Sha256, 32>(password.as_bytes(), &salt, 100_000);
    let cipher = Aes256Gcm::new_from_slice(&key).unwrap();
    let ct_and_tag = cipher
        .encrypt(Nonce::from_slice(&nonce), payload_json.as_bytes())
        .unwrap();
    // aes-gcm appends the 16-byte tag; v1 stores it separately.
    let (ct, tag) = ct_and_tag.split_at(ct_and_tag.len() - 16);

    let mut out = Vec::new();
    out.extend_from_slice(b"OTPB");
    out.extend_from_slice(&1u32.to_le_bytes());
    out.extend_from_slice(&salt);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(tag);
    out.extend_from_slice(ct);
    out
}

#[test]
fn import_v1_backup_converts_model() {
    let json = r##"{
        "version": 1,
        "exportedAt": "2024-01-01T12:00:00Z",
        "accounts": [
            { "type": "totp", "secret": "jbswy3dpehpk3pxp", "issuer": "GitHub",
              "accountName": "user@example.com" },
            { "type": "hotp", "secret": "GEZDGNBVGY3TQOJQ", "accountName": "hotp-only",
              "algorithm": "SHA256", "digits": 8, "counter": 3 }
        ],
        "folders": [
            { "id": "660e8400-e29b-41d4-a716-446655440001", "name": "Work",
              "icon": "briefcase", "color": "#0078D4" },
            { "name": "NoId" }
        ]
    }"##;
    let backup = make_v1_backup(json, "hunter2");

    let payload = import_backup_v1(&backup, "hunter2", NOW).expect("import");
    assert_eq!(payload.accounts.len(), 2);
    assert_eq!(payload.folders.len(), 2);

    let a0 = &payload.accounts[0];
    assert_eq!(a0.otp_type, OtpType::Totp);
    assert_eq!(
        a0.secret, "JBSWY3DPEHPK3PXP",
        "secret normalized to uppercase"
    );
    assert_eq!(a0.digits, 6, "default digits");
    assert_eq!(a0.period, 30, "default period");
    assert_eq!(a0.algorithm, HashAlgorithm::Sha1, "default algorithm");
    assert!(!a0.id.is_empty(), "id assigned");
    // exportedAt (2024-01-01T12:00:00Z) → epoch ms.
    assert_eq!(a0.created_at, 1_704_110_400_000);

    let a1 = &payload.accounts[1];
    assert_eq!(a1.otp_type, OtpType::Hotp);
    assert_eq!(a1.algorithm, HashAlgorithm::Sha256);
    assert_eq!(a1.digits, 8);
    assert_eq!(a1.counter, 3);

    // Folder without an id gets a fresh UUID.
    let noid = payload.folders.iter().find(|f| f.name == "NoId").unwrap();
    assert!(!noid.id.is_empty());
}

#[test]
fn import_v1_wrong_password_errors() {
    let json = r#"{ "version": 1, "exportedAt": "2024-01-01T12:00:00Z", "accounts": [] }"#;
    let backup = make_v1_backup(json, "hunter2");
    match import_backup_v1(&backup, "wrong", NOW) {
        Err(VaultError::WrongPassword) => {}
        Ok(_) => panic!("unexpectedly succeeded, expected WrongPassword"),
        Err(other) => panic!("expected WrongPassword, got {other:?}"),
    }
}

#[test]
fn import_v1_bad_magic_is_corrupt() {
    let mut backup = make_v1_backup(
        r#"{"version":1,"exportedAt":"2024-01-01T12:00:00Z","accounts":[]}"#,
        "pw",
    );
    backup[0] = b'Z';
    match import_backup_v1(&backup, "pw", NOW) {
        Err(VaultError::Corrupt(_)) => {}
        Ok(_) => panic!("unexpectedly succeeded, expected Corrupt"),
        Err(other) => panic!("expected Corrupt, got {other:?}"),
    }
}

// -- committed fixture (format stability guard) ----------------------------

#[test]
fn opens_committed_v2_fixture() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/vault-v2.otpvault"
    );
    let data = std::fs::read(path).expect("read fixture (run `cargo run --example gen_fixture`)");
    let vault = Vault::open_with_password(&data, "test-password-123").expect("open fixture");
    assert!(
        !vault.payload().accounts.is_empty(),
        "fixture should contain accounts"
    );
    // Round-trips through the key path too.
    let vmk = vault.vmk();
    Vault::open_with_key(&data, &vmk).expect("key path open of fixture");
}

// -- file I/O --------------------------------------------------------------

#[test]
fn atomic_file_round_trip() {
    let dir = std::env::temp_dir().join(format!("otpvault-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("vault.otpvault");

    let (mut v, vmk) = new_vault_with_account();
    let bytes = v.to_bytes(NOW).expect("to_bytes");
    otpeek_vault::write_vault_file(&path, &bytes).expect("write");
    let read = otpeek_vault::read_vault_file(&path).expect("read");
    assert_eq!(read, bytes);

    let opened = Vault::open_with_key(&read, &vmk).expect("open");
    assert_eq!(opened.payload().accounts.len(), 1);

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn concurrent_saves_reject_one_stale_snapshot_and_allow_reload() {
    use std::sync::Barrier;
    let dir = std::env::temp_dir().join(uuid::Uuid::new_v4().to_string());
    std::fs::create_dir(&dir).unwrap();
    let path = dir.join("vault.otpvault");
    let (mut original, vmk) = new_vault_with_account();
    original.save_to_file(&path, NOW).unwrap();

    let read = otpeek_vault::read_vault_file(&path).unwrap();
    let mut first = Vault::open_with_key(&read, &vmk).unwrap();
    let mut second = Vault::open_with_key(&read, &vmk).unwrap();
    first.payload_mut().accounts.push(sample_account("first"));
    second.payload_mut().accounts.push(sample_account("second"));
    let generation = second.generation();
    let barrier = Barrier::new(2);
    let outcomes = std::thread::scope(|scope| {
        let first = scope.spawn(|| {
            barrier.wait();
            first.save_to_file(&path, NOW)
        });
        barrier.wait();
        let second_result = second.save_to_file(&path, NOW);
        (first.join().unwrap(), second_result)
    });
    match outcomes {
        (Ok(()), Err(VaultError::StaleFile)) | (Err(VaultError::StaleFile), Ok(())) => {}
        other => panic!("one save must report a stale snapshot, got {other:?}"),
    }
    assert_eq!(first.generation().min(second.generation()), generation);

    let read = otpeek_vault::read_vault_file(&path).unwrap();
    let mut reloaded = Vault::open_with_key(&read, &vmk).unwrap();
    assert_eq!(reloaded.payload().accounts.len(), 2);
    assert!(matches!(
        reloaded.restore_to_new_file(&path, NOW),
        Err(VaultError::StaleFile)
    ));
    let restored_path = dir.join("restored.otpvault");
    let mut restored = Vault::open_with_key(&read, &vmk).unwrap();
    restored.restore_to_new_file(&restored_path, NOW).unwrap();
    restored.save_to_file(&restored_path, NOW).unwrap();
    reloaded
        .payload_mut()
        .accounts
        .push(sample_account("retried"));
    reloaded.save_to_file(&path, NOW).unwrap();

    let mut new = Vault::create("another password").unwrap();
    assert!(matches!(
        new.save_to_file(&path, NOW),
        Err(VaultError::StaleFile)
    ));
    assert_eq!(new.generation(), 0);
    assert_eq!(
        Vault::open_with_key(&otpeek_vault::read_vault_file(&path).unwrap(), &vmk)
            .unwrap()
            .payload()
            .accounts
            .len(),
        3
    );
    std::fs::remove_dir_all(&dir).unwrap();
}
