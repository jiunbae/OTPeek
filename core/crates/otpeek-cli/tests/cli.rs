//! Integration tests for the `otp` CLI.
//!
//! These drive the real binary against a temp vault, using `$OTPEEK_VAULT` and
//! `$OTPEEK_VAULT_PASSWORD` so no keyring / interactive prompt is involved.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use assert_cmd::Command;
use predicates::prelude::*;
use tempfile::TempDir;

const PW: &str = "test-password-123";
const SECRET: &str = "JBSWY3DPEHPK3PXP";

fn otp(vault: &Path) -> Command {
    let mut cmd = Command::cargo_bin("otpeek").expect("binary builds");
    cmd.env("OTPEEK_VAULT", vault)
        .env("OTPEEK_VAULT_PASSWORD", PW)
        .env_remove("OTPEEK_BACKUP_PASSWORD");
    cmd
}

fn vault_in(dir: &TempDir) -> PathBuf {
    dir.path().join("vault.otpvault")
}

fn init(vault: &Path) {
    otp(vault).arg("init").assert().success();
}

#[test]
fn init_creates_vault_and_lists_empty() {
    let dir = TempDir::new().unwrap();
    let v = vault_in(&dir);
    init(&v);
    assert!(v.exists(), "vault file should exist after init");
    otp(&v).arg("list").assert().success();
}

#[test]
fn init_twice_fails() {
    let dir = TempDir::new().unwrap();
    let v = vault_in(&dir);
    init(&v);
    otp(&v).arg("init").assert().failure().code(1);
}

#[test]
fn add_from_uri_then_list_and_code() {
    let dir = TempDir::new().unwrap();
    let v = vault_in(&dir);
    init(&v);
    otp(&v)
        .args([
            "add",
            "otpauth://totp/GitHub:me@example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub",
        ])
        .assert()
        .success();
    otp(&v)
        .arg("list")
        .assert()
        .success()
        .stdout(predicate::str::contains("GitHub"));
    otp(&v)
        .args(["code", "GitHub"])
        .assert()
        .success()
        .stdout(predicate::str::is_match(r"^\d{6}\n$").unwrap());
    otp(&v)
        .args(["code", "GitHub", "--advance"])
        .assert()
        .failure()
        .stdout("")
        .stderr(predicate::str::contains(
            "--advance requires a HOTP account",
        ));
}

#[test]
fn add_manual_and_code() {
    let dir = TempDir::new().unwrap();
    let v = vault_in(&dir);
    init(&v);
    otp(&v)
        .args([
            "add",
            "--issuer",
            "Acme",
            "--account",
            "bob",
            "--secret",
            SECRET,
        ])
        .assert()
        .success();
    otp(&v)
        .args(["code", "Acme"])
        .assert()
        .success()
        .stdout(predicate::str::is_match(r"^\d{6}\n$").unwrap());
}

#[test]
fn list_json_output() {
    let dir = TempDir::new().unwrap();
    let v = vault_in(&dir);
    init(&v);
    otp(&v)
        .args([
            "add",
            "--issuer",
            "Acme",
            "--account",
            "bob",
            "--secret",
            SECRET,
        ])
        .assert()
        .success();
    otp(&v)
        .args(["list", "--json"])
        .assert()
        .success()
        .stdout(predicate::str::contains("accountName"))
        .stdout(predicate::str::contains("Acme"))
        .stdout(predicate::str::contains("\"secret\"").not())
        .stdout(predicate::str::contains(SECRET).not());
}

fn add_hotp(vault: &Path) {
    otp(vault)
        .args([
            "add",
            "otpauth://hotp/Example?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&counter=0",
        ])
        .assert()
        .success();
}

#[test]
fn hotp_peek_and_advance() {
    let dir = TempDir::new().unwrap();
    let vault = vault_in(&dir);
    init(&vault);
    add_hotp(&vault);
    let before = std::fs::read(&vault).unwrap();
    for _ in 0..2 {
        otp(&vault)
            .args(["code", "Example"])
            .assert()
            .success()
            .stdout("755224\n");
    }
    assert_eq!(std::fs::read(&vault).unwrap(), before);
    otp(&vault)
        .args(["code", "Example", "--advance", "--watch"])
        .assert()
        .code(2)
        .stdout("");
    otp(&vault)
        .args(["code", "Example", "--advance"])
        .assert()
        .success()
        .stdout("755224\n");
    otp(&vault)
        .args(["code", "Example"])
        .assert()
        .success()
        .stdout("287082\n");

    otp(&vault)
        .args([
            "add",
            "otpauth://hotp/Exhausted?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&counter=18446744073709551615",
        ])
        .assert()
        .success();
    otp(&vault)
        .args(["code", "Exhausted", "--advance"])
        .assert()
        .failure()
        .stdout("")
        .stderr(predicate::str::contains("HOTP counter is exhausted"));
}

#[test]
fn concurrent_hotp_advances_use_consecutive_counters() {
    let dir = TempDir::new().unwrap();
    let vault = vault_in(&dir);
    init(&vault);
    add_hotp(&vault);

    let start = || {
        std::process::Command::new(env!("CARGO_BIN_EXE_otpeek"))
            .env("OTPEEK_VAULT", &vault)
            .env("OTPEEK_VAULT_PASSWORD", PW)
            .args(["code", "Example", "--advance"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap()
    };
    let first = start();
    let second = start();
    let mut codes = Vec::new();
    for child in [first, second] {
        let output = child.wait_with_output().unwrap();
        if output.status.success() {
            codes.push(String::from_utf8(output.stdout).unwrap());
        } else {
            assert!(output.stdout.is_empty(), "{output:?}");
            assert!(
                String::from_utf8_lossy(&output.stderr).contains("vault file changed"),
                "{output:?}"
            );
        }
    }
    if codes.len() == 1 {
        let output = otp(&vault)
            .args(["code", "Example", "--advance"])
            .assert()
            .success();
        codes.push(String::from_utf8(output.get_output().stdout.clone()).unwrap());
    }
    codes.sort();
    assert_eq!(codes, ["287082\n", "755224\n"]);
    otp(&vault)
        .args(["code", "Example"])
        .assert()
        .success()
        .stdout("359152\n");
}

#[test]
fn restore_creates_only_a_new_vault() {
    let dir = TempDir::new().unwrap();
    let source = dir.path().join("backup.otpvault");
    init(&source);
    add_hotp(&source);

    let occupied = vault_in(&dir);
    init(&occupied);
    let before = std::fs::read(&occupied).unwrap();
    otp(&occupied)
        .arg("restore")
        .arg(&source)
        .assert()
        .failure()
        .stderr(predicate::str::contains("choose an unused path"));
    assert_eq!(std::fs::read(&occupied).unwrap(), before);

    let fresh = dir.path().join("fresh").join("vault.otpvault");
    otp(&fresh)
        .env_remove("OTPEEK_VAULT")
        .arg("--vault")
        .arg(&fresh)
        .arg("restore")
        .arg(&source)
        .assert()
        .success();
    otp(&fresh)
        .args(["code", "Example"])
        .assert()
        .success()
        .stdout("755224\n");
}

#[test]
fn webdav_restore_rejects_http() {
    let dir = TempDir::new().unwrap();
    let vault = vault_in(&dir);
    otp(&vault)
        .timeout(Duration::from_secs(5))
        .env("OTP_WEBDAV_PASSWORD", "demo")
        .args([
            "restore",
            "http://example.test/backup.otpvault",
            "--user",
            "alice",
        ])
        .assert()
        .failure()
        .stderr(predicate::str::contains("WebDAV requires an HTTPS URL"));
    assert!(!vault.exists());
}

#[test]
fn remove_account() {
    let dir = TempDir::new().unwrap();
    let v = vault_in(&dir);
    init(&v);
    otp(&v)
        .args([
            "add",
            "--issuer",
            "Acme",
            "--account",
            "bob",
            "--secret",
            SECRET,
        ])
        .assert()
        .success();
    otp(&v).args(["rm", "Acme", "--yes"]).assert().success();
    otp(&v)
        .arg("list")
        .assert()
        .success()
        .stdout(predicate::str::contains("Acme").not());
}

#[test]
fn folder_lifecycle() {
    let dir = TempDir::new().unwrap();
    let v = vault_in(&dir);
    init(&v);
    otp(&v).args(["folder", "add", "Work"]).assert().success();
    otp(&v)
        .args(["folder", "list"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Work"));
    otp(&v).args(["folder", "rm", "Work"]).assert().success();
    otp(&v)
        .args(["folder", "list"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Work").not());
}

#[test]
fn ambiguous_query_exits_2() {
    let dir = TempDir::new().unwrap();
    let v = vault_in(&dir);
    init(&v);
    otp(&v)
        .args([
            "add",
            "--issuer",
            "GitHub",
            "--account",
            "a",
            "--secret",
            SECRET,
        ])
        .assert()
        .success();
    otp(&v)
        .args([
            "add",
            "--issuer",
            "GitLab",
            "--account",
            "b",
            "--secret",
            SECRET,
        ])
        .assert()
        .success();
    otp(&v).args(["code", "Git"]).assert().code(2);
}

#[test]
fn missing_query_exits_1() {
    let dir = TempDir::new().unwrap();
    let v = vault_in(&dir);
    init(&v);
    otp(&v).args(["code", "nope"]).assert().failure().code(1);
}

#[test]
fn export_then_import_roundtrip() {
    let dir = TempDir::new().unwrap();
    let v = vault_in(&dir);
    init(&v);
    otp(&v)
        .args([
            "add",
            "--issuer",
            "Acme",
            "--account",
            "bob",
            "--secret",
            SECRET,
        ])
        .assert()
        .success();

    let backup = dir.path().join("backup.otpvault");
    otp(&v)
        .args(["export", backup.to_str().unwrap(), "--password-stdin"])
        .write_stdin(PW)
        .assert()
        .success();
    assert!(backup.exists());

    let dir2 = TempDir::new().unwrap();
    let v2 = vault_in(&dir2);
    init(&v2);
    otp(&v2)
        .args(["import", backup.to_str().unwrap(), "--merge"])
        .assert()
        .success();
    otp(&v2)
        .arg("list")
        .assert()
        .success()
        .stdout(predicate::str::contains("Acme"));
}

#[test]
fn export_cannot_replace_the_active_vault() {
    let dir = TempDir::new().unwrap();
    let vault = vault_in(&dir);
    init(&vault);
    add_hotp(&vault);
    let original = std::fs::read(&vault).unwrap();

    otp(&vault)
        .arg("export")
        .arg(&vault)
        .env("OTPEEK_BACKUP_PASSWORD", "backup-only-pw")
        .assert()
        .failure()
        .stderr(predicate::str::contains("choose an unused output path"));
    assert_eq!(std::fs::read(&vault).unwrap(), original);
}

#[test]
fn change_password() {
    let dir = TempDir::new().unwrap();
    let v = vault_in(&dir);
    init(&v);
    otp(&v)
        .args([
            "add",
            "--issuer",
            "Acme",
            "--account",
            "bob",
            "--secret",
            SECRET,
        ])
        .assert()
        .success();

    // old = $OTPEEK_VAULT_PASSWORD, new = $OTPEEK_NEW_PASSWORD
    otp(&v)
        .env("OTPEEK_NEW_PASSWORD", "brand-new-pw-456")
        .arg("passwd")
        .assert()
        .success();

    // Opening with the new password succeeds and still shows the account.
    Command::cargo_bin("otpeek")
        .unwrap()
        .env("OTPEEK_VAULT", &v)
        .env("OTPEEK_VAULT_PASSWORD", "brand-new-pw-456")
        .arg("list")
        .assert()
        .success()
        .stdout(predicate::str::contains("Acme"));
}

#[test]
fn uri_roundtrip() {
    let dir = TempDir::new().unwrap();
    let v = vault_in(&dir);
    init(&v);
    otp(&v)
        .args([
            "add",
            "otpauth://totp/GitHub:me@example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub",
        ])
        .assert()
        .success();
    otp(&v)
        .args(["uri", "GitHub"])
        .assert()
        .success()
        .stdout(predicate::str::contains("otpauth://totp/"));
}

#[test]
fn sync_status_when_unconfigured() {
    let dir = TempDir::new().unwrap();
    let v = vault_in(&dir);
    init(&v);
    // Point config to an isolated dir so a real user config isn't read.
    otp(&v)
        .env("XDG_CONFIG_HOME", dir.path())
        .args(["sync", "status"])
        .assert()
        .success()
        .stdout(predicate::str::contains("not configured").or(predicate::str::contains("Sync")));
}

#[test]
fn merge_import_resurrects_deleted_account() {
    let dir = TempDir::new().unwrap();
    let v = vault_in(&dir);
    init(&v);
    otp(&v)
        .args([
            "add",
            "--issuer",
            "Acme",
            "--account",
            "bob",
            "--secret",
            SECRET,
        ])
        .assert()
        .success();

    // Export with a password DIFFERENT from the vault password, then delete.
    let backup = dir.path().join("backup.otpvault");
    otp(&v)
        .args(["export", backup.to_str().unwrap(), "--password-stdin"])
        .write_stdin("backup-only-pw")
        .assert()
        .success();
    otp(&v).args(["rm", "acme", "--yes"]).assert().success();
    otp(&v)
        .arg("list")
        .assert()
        .success()
        .stdout(predicate::str::contains("Acme").not());

    // Merge import must resurrect the tombstoned account, decrypting the
    // backup via $OTPEEK_BACKUP_PASSWORD (vault stays on $OTPEEK_VAULT_PASSWORD).
    otp(&v)
        .env("OTPEEK_BACKUP_PASSWORD", "backup-only-pw")
        .args(["import", backup.to_str().unwrap(), "--merge"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Imported 1"));
    otp(&v)
        .arg("list")
        .assert()
        .success()
        .stdout(predicate::str::contains("Acme"));
}
