//! Host-only contract checks for a prospective Android shell. Fixture data only.
use otpeek_ffi::{HashAlgorithm, OtpAccount, OtpClient, OtpError, OtpType};
use std::path::PathBuf;

struct FixtureDir(PathBuf);

impl FixtureDir {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("otpeek-android-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&path).expect("fixture directory");
        Self(path)
    }

    fn path(&self, name: &str) -> String {
        self.0.join(name).to_str().expect("fixture path").to_owned()
    }
}

impl Drop for FixtureDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn hotp_fixture() -> OtpAccount {
    OtpAccount {
        id: String::new(),
        otp_type: OtpType::Hotp,
        // RFC 4226 public test vector, not a user credential.
        secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ".into(),
        issuer: None,
        account_name: "RFC fixture".into(),
        algorithm: HashAlgorithm::Sha1,
        digits: 6,
        period: 30,
        counter: 0,
        folder_id: None,
        is_favorite: false,
        sort_order: 0,
        icon: None,
        color: None,
        created_at: 0,
        updated_at: 0,
        deleted_at: None,
    }
}

#[test]
fn hotp_consumes_current_counter_and_survives_reopen() {
    let dir = FixtureDir::new();
    let path = dir.path("vault.otpvault");
    let client = OtpClient::create(path.clone(), "fixture-master".into()).unwrap();
    let id = client.add_account(hotp_fixture()).unwrap().id;
    assert_eq!(client.code(id.clone(), 0).unwrap().code, "755224");
    assert_eq!(client.get_account(id.clone()).unwrap().counter, 0);
    assert_eq!(client.next_hotp(id.clone()).unwrap().code, "755224");
    let vmk = client.vault_key();
    drop(client);
    let reopened = OtpClient::open_with_key(path, vmk).unwrap();
    assert_eq!(reopened.get_account(id.clone()).unwrap().counter, 1);
    assert_eq!(reopened.code(id, 0).unwrap().code, "287082");
    assert!(reopened.codes_at(0).is_empty(), "batch codes exclude HOTP");
}

#[test]
fn backup_key_is_independent_and_failed_import_preserves_vault() {
    let dir = FixtureDir::new();
    let path = dir.path("source.otpvault");
    let client = OtpClient::create(path.clone(), "fixture-master".into()).unwrap();
    let id = client.add_account(hotp_fixture()).unwrap().id;
    let backup = client.export_backup("fixture-backup".into()).unwrap();
    let restored = OtpClient::restore(
        dir.path("restored.otpvault"),
        backup.clone(),
        "fixture-backup".into(),
    )
    .unwrap();
    assert!(
        client.vault_key() != restored.vault_key(),
        "backup gets a new VMK"
    );
    assert_eq!(restored.get_account(id.clone()).unwrap().counter, 0);
    let before = std::fs::read(&path).unwrap();
    assert!(matches!(
        client.import_backup(backup.clone(), "wrong-fixture-password".into(), false),
        Err(OtpError::WrongPassword)
    ));
    assert!(std::fs::read(&path).unwrap() == before);
    client.next_hotp(id.clone()).unwrap();
    assert_eq!(
        client
            .import_backup(backup.clone(), "fixture-backup".into(), true)
            .unwrap(),
        0
    );
    assert_eq!(
        client.get_account(id.clone()).unwrap().counter,
        1,
        "live duplicate is skipped"
    );
    client
        .import_backup(backup, "fixture-backup".into(), false)
        .unwrap();
    assert_eq!(
        client.get_account(id).unwrap().counter,
        0,
        "replace import can regress HOTP"
    );
}
