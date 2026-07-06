//! Regenerates the committed format-stability fixture
//! `tests/fixtures/vault-v2.otpvault` (password "test-password-123").
//!
//! Run: `cargo run -p otpeek-vault --example gen_fixture`
//! The bytes are non-deterministic (random VMK/salt/nonce) but any valid file
//! guards the on-disk format against silent breakage.

use otpeek_core::{HashAlgorithm, OtpAccount, OtpFolder, OtpType};
use otpeek_vault::Vault;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut vault = Vault::create("test-password-123")?;
    let now = 1_730_000_000_000i64;
    vault.payload_mut().folders.push(OtpFolder {
        id: "660e8400-e29b-41d4-a716-446655440001".into(),
        name: "Work".into(),
        icon: Some("briefcase".into()),
        color: Some("#0078D4".into()),
        sort_order: 0,
        created_at: now,
        updated_at: now,
        deleted_at: None,
    });
    vault.payload_mut().accounts.push(OtpAccount {
        id: "11111111-1111-4111-8111-111111111111".into(),
        otp_type: OtpType::Totp,
        secret: "JBSWY3DPEHPK3PXP".into(),
        issuer: Some("GitHub".into()),
        account_name: "octocat".into(),
        algorithm: HashAlgorithm::Sha1,
        digits: 6,
        period: 30,
        counter: 0,
        folder_id: Some("660e8400-e29b-41d4-a716-446655440001".into()),
        is_favorite: true,
        sort_order: 0,
        icon: None,
        color: None,
        created_at: now,
        updated_at: now,
        deleted_at: None,
    });
    vault.payload_mut().accounts.push(OtpAccount {
        id: "22222222-2222-4222-8222-222222222222".into(),
        otp_type: OtpType::Hotp,
        secret: "GEZDGNBVGY3TQOJQ".into(),
        issuer: Some("Example".into()),
        account_name: "hotp@example.com".into(),
        algorithm: HashAlgorithm::Sha256,
        digits: 8,
        period: 30,
        counter: 5,
        folder_id: None,
        is_favorite: false,
        sort_order: 1,
        icon: None,
        color: None,
        created_at: now,
        updated_at: now,
        deleted_at: None,
    });

    let bytes = vault.to_bytes(now)?;
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/vault-v2.otpvault"
    );
    std::fs::write(path, &bytes)?;
    println!("wrote {} ({} bytes)", path, bytes.len());
    Ok(())
}
