//! otpauth:// URI parsing / serialization and round-trip stability.

use otp_core::{
    generate_code, parse_otpauth_uri, to_otpauth_uri, HashAlgorithm, OtpAccount, OtpType,
};

const NOW: i64 = 1_700_000_000_000;

#[test]
fn parse_totp_with_defaults() {
    let a = parse_otpauth_uri(
        "otpauth://totp/Example:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example",
        NOW,
    )
    .unwrap();
    assert_eq!(a.otp_type, OtpType::Totp);
    assert_eq!(a.secret, "JBSWY3DPEHPK3PXP");
    assert_eq!(a.issuer.as_deref(), Some("Example"));
    assert_eq!(a.account_name, "alice@example.com");
    assert_eq!(a.algorithm, HashAlgorithm::Sha1);
    assert_eq!(a.digits, 6);
    assert_eq!(a.period, 30);
    assert_eq!(a.created_at, NOW);
    assert_eq!(a.updated_at, NOW);
    assert!(!a.id.is_empty());
}

#[test]
fn issuer_param_takes_precedence_over_label() {
    let a = parse_otpauth_uri(
        "otpauth://totp/LabelIssuer:acct?secret=JBSWY3DPEHPK3PXP&issuer=ParamIssuer",
        NOW,
    )
    .unwrap();
    assert_eq!(a.issuer.as_deref(), Some("ParamIssuer"));
    assert_eq!(a.account_name, "acct");
}

#[test]
fn label_issuer_used_when_no_param() {
    let a = parse_otpauth_uri(
        "otpauth://totp/LabelIssuer:acct?secret=JBSWY3DPEHPK3PXP",
        NOW,
    )
    .unwrap();
    assert_eq!(a.issuer.as_deref(), Some("LabelIssuer"));
    assert_eq!(a.account_name, "acct");
}

#[test]
fn label_without_issuer() {
    let a = parse_otpauth_uri("otpauth://totp/justme?secret=JBSWY3DPEHPK3PXP", NOW).unwrap();
    assert_eq!(a.issuer, None);
    assert_eq!(a.account_name, "justme");
}

#[test]
fn parse_hotp_with_counter() {
    let a = parse_otpauth_uri(
        "otpauth://hotp/Svc:me?secret=JBSWY3DPEHPK3PXP&counter=42&algorithm=SHA256&digits=8",
        NOW,
    )
    .unwrap();
    assert_eq!(a.otp_type, OtpType::Hotp);
    assert_eq!(a.counter, 42);
    assert_eq!(a.algorithm, HashAlgorithm::Sha256);
    assert_eq!(a.digits, 8);
}

#[test]
fn missing_secret_errors() {
    assert!(parse_otpauth_uri("otpauth://totp/Svc:me?issuer=Svc", NOW).is_err());
}

#[test]
fn bad_scheme_errors() {
    assert!(parse_otpauth_uri("https://totp/Svc:me?secret=JBSWY3DPEHPK3PXP", NOW).is_err());
}

#[test]
fn special_characters_in_label_roundtrip() {
    // Space and reserved characters exercised through percent-encoding.
    let uri = "otpauth://totp/My%20Company:user%2Btag%40mail.com?secret=JBSWY3DPEHPK3PXP&issuer=My%20Company";
    let a = parse_otpauth_uri(uri, NOW).unwrap();
    assert_eq!(a.issuer.as_deref(), Some("My Company"));
    assert_eq!(a.account_name, "user+tag@mail.com");

    // Round-trip: serialize then parse again must preserve semantic fields.
    let out = to_otpauth_uri(&a);
    let b = parse_otpauth_uri(&out, NOW).unwrap();
    assert_eq!(a.issuer, b.issuer);
    assert_eq!(a.account_name, b.account_name);
    assert_eq!(a.secret, b.secret);
    assert_eq!(a.otp_type, b.otp_type);
    assert_eq!(a.algorithm, b.algorithm);
    assert_eq!(a.digits, b.digits);
    assert_eq!(a.period, b.period);
}

#[test]
fn roundtrip_all_variants() {
    let accounts = [
        make(
            OtpType::Totp,
            HashAlgorithm::Sha1,
            6,
            30,
            0,
            Some("GitHub"),
            "me",
        ),
        make(OtpType::Totp, HashAlgorithm::Sha512, 8, 60, 0, None, "solo"),
        make(
            OtpType::Hotp,
            HashAlgorithm::Sha256,
            7,
            30,
            99,
            Some("Bank"),
            "acct:with:colons",
        ),
    ];
    for a in accounts {
        let uri = to_otpauth_uri(&a);
        let b = parse_otpauth_uri(&uri, NOW).unwrap();
        assert_eq!(a.otp_type, b.otp_type, "uri={uri}");
        assert_eq!(a.secret, b.secret, "uri={uri}");
        assert_eq!(a.issuer, b.issuer, "uri={uri}");
        assert_eq!(a.account_name, b.account_name, "uri={uri}");
        assert_eq!(a.algorithm, b.algorithm, "uri={uri}");
        assert_eq!(a.digits, b.digits, "uri={uri}");
        if a.otp_type == OtpType::Totp {
            assert_eq!(a.period, b.period, "uri={uri}");
        } else {
            assert_eq!(a.counter, b.counter, "uri={uri}");
        }
    }
}

#[test]
fn generate_code_totp_window() {
    let a = make(OtpType::Totp, HashAlgorithm::Sha1, 6, 30, 0, Some("X"), "y");
    let code = generate_code(&a, 59_000).unwrap();
    // period window [30_000, 60_000) for t=59s
    assert_eq!(code.valid_from, 30_000);
    assert_eq!(code.valid_until, 60_000);
    assert_eq!(code.code.len(), 6);
}

#[test]
fn generate_code_hotp_no_mutation() {
    let a = make(OtpType::Hotp, HashAlgorithm::Sha1, 6, 30, 0, Some("X"), "y");
    let code = generate_code(&a, 123).unwrap();
    assert_eq!(code.valid_from, 123);
    assert_eq!(code.valid_until, i64::MAX);
    assert_eq!(a.counter, 0, "generate_code must not mutate the counter");
    // RFC 4226 counter 0 vector for the standard seed.
}

fn make(
    otp_type: OtpType,
    algorithm: HashAlgorithm,
    digits: u32,
    period: u32,
    counter: u64,
    issuer: Option<&str>,
    account_name: &str,
) -> OtpAccount {
    OtpAccount {
        id: "id".to_string(),
        otp_type,
        secret: "JBSWY3DPEHPK3PXP".to_string(),
        issuer: issuer.map(|s| s.to_string()),
        account_name: account_name.to_string(),
        algorithm,
        digits,
        period,
        counter,
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
