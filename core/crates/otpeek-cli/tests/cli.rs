//! Integration tests for the `otp` CLI.
//!
//! These drive the real binary against a temp vault, using `$OTPEEK_VAULT` and
//! `$OTPEEK_VAULT_PASSWORD` so no keyring / interactive prompt is involved.

use std::path::{Path, PathBuf};

use assert_cmd::Command;
use predicates::prelude::*;
use tempfile::TempDir;

const PW: &str = "test-password-123";
const SECRET: &str = "JBSWY3DPEHPK3PXP";

fn otp(vault: &Path) -> Command {
    let mut cmd = Command::cargo_bin("otpeek").expect("binary builds");
    cmd.env("OTPEEK_VAULT", vault)
        .env("OTPEEK_VAULT_PASSWORD", PW);
    cmd
}

fn isolated(home: &Path) -> Command {
    let mut cmd = Command::cargo_bin("otpeek").expect("binary builds");
    cmd.env("HOME", home)
        .env("OTPEEK_VAULT_PASSWORD", PW)
        .env_remove("OTPEEK_VAULT");
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
fn saved_vault_selection_becomes_the_default() {
    let dir = TempDir::new().unwrap();
    let vault = dir.path().join("shared").join("vault.otpvault");

    isolated(dir.path())
        .args(["--vault", vault.to_str().unwrap(), "init"])
        .assert()
        .success();
    isolated(dir.path())
        .args(["vault", "use", vault.to_str().unwrap()])
        .assert()
        .success()
        .stdout(predicate::str::contains("Selected vault"));
    isolated(dir.path())
        .args(["vault", "current"])
        .assert()
        .success()
        .stdout(predicate::str::contains(vault.to_str().unwrap()))
        .stdout(predicate::str::contains("saved selection"));
    isolated(dir.path()).arg("list").assert().success();
}

#[test]
fn vault_flag_overrides_environment_and_saved_selection() {
    let dir = TempDir::new().unwrap();
    let configured = dir.path().join("configured.otpvault");
    let from_env = dir.path().join("environment.otpvault");
    let from_flag = dir.path().join("flag.otpvault");

    isolated(dir.path())
        .args(["vault", "use", configured.to_str().unwrap()])
        .assert()
        .success();
    isolated(dir.path())
        .env("OTPEEK_VAULT", &from_env)
        .args(["--vault", from_flag.to_str().unwrap(), "vault", "current"])
        .assert()
        .success()
        .stdout(predicate::str::contains(from_flag.to_str().unwrap()))
        .stdout(predicate::str::contains("--vault"))
        .stdout(predicate::str::contains(from_env.to_str().unwrap()).not())
        .stdout(predicate::str::contains(configured.to_str().unwrap()).not());
}

#[test]
fn vault_list_marks_the_effective_vault() {
    let dir = TempDir::new().unwrap();
    let vault = dir.path().join("chosen.otpvault");
    isolated(dir.path())
        .args(["vault", "use", vault.to_str().unwrap()])
        .assert()
        .success();

    isolated(dir.path())
        .args(["vault", "list"])
        .assert()
        .success()
        .stdout(predicate::str::contains(
            "Effective source: saved selection",
        ))
        .stdout(predicate::str::contains("* configured"))
        .stdout(predicate::str::contains(vault.to_str().unwrap()));
}

#[cfg(target_os = "macos")]
#[test]
fn macos_alias_selects_the_app_group_vault() {
    let dir = TempDir::new().unwrap();
    let expected = dir
        .path()
        .join("Library/Group Containers/group.com.otpeek.app/vault.otpvault");

    isolated(dir.path())
        .args(["vault", "use", "macos"])
        .assert()
        .success()
        .stdout(predicate::str::contains(expected.to_str().unwrap()));
    isolated(dir.path())
        .args(["vault", "current"])
        .assert()
        .success()
        .stdout(predicate::str::contains(expected.to_str().unwrap()));
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
        .stdout(predicate::str::contains("Acme"));
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
