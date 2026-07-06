//! otpauth-migration:// decode against a synthetic protobuf payload built byte-by-byte.

use data_encoding::{BASE32_NOPAD, BASE64};
use otpeek_core::{parse_migration_uri, HashAlgorithm, OtpType};

const NOW: i64 = 1_700_000_000_000;

/// Encode a base-128 varint.
fn varint(mut v: u64, out: &mut Vec<u8>) {
    loop {
        let mut byte = (v & 0x7f) as u8;
        v >>= 7;
        if v != 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if v == 0 {
            break;
        }
    }
}

fn tag(field: u64, wire: u64, out: &mut Vec<u8>) {
    varint((field << 3) | wire, out);
}

fn len_field(field: u64, data: &[u8], out: &mut Vec<u8>) {
    tag(field, 2, out);
    varint(data.len() as u64, out);
    out.extend_from_slice(data);
}

fn varint_field(field: u64, value: u64, out: &mut Vec<u8>) {
    tag(field, 0, out);
    varint(value, out);
}

fn build_otp_params(
    secret: &[u8],
    name: &str,
    issuer: &str,
    algorithm: u64,
    digits: u64,
    otp_type: u64,
    counter: Option<u64>,
) -> Vec<u8> {
    let mut b = Vec::new();
    len_field(1, secret, &mut b);
    len_field(2, name.as_bytes(), &mut b);
    if !issuer.is_empty() {
        len_field(3, issuer.as_bytes(), &mut b);
    }
    varint_field(4, algorithm, &mut b);
    varint_field(5, digits, &mut b);
    varint_field(6, otp_type, &mut b);
    if let Some(c) = counter {
        varint_field(7, c, &mut b);
    }
    b
}

#[test]
fn decodes_synthetic_payload() {
    let seed = b"12345678901234567890";
    let p1 = build_otp_params(seed, "alice@example.com", "Example", 1, 1, 2, None);
    let p2 = build_otp_params(&[0x00, 0x01, 0x02, 0x03, 0x04], "bob", "", 2, 2, 1, Some(5));

    let mut payload = Vec::new();
    len_field(1, &p1, &mut payload); // repeated otp_parameters
    len_field(1, &p2, &mut payload);
    // an ignored trailing scalar field (version = 2)
    varint_field(2, 1, &mut payload);

    let data = BASE64.encode(&payload);
    let uri = format!("otpauth-migration://offline?data={data}");

    let accounts = parse_migration_uri(&uri, NOW).unwrap();
    assert_eq!(accounts.len(), 2);

    let a = &accounts[0];
    assert_eq!(a.otp_type, OtpType::Totp);
    assert_eq!(a.algorithm, HashAlgorithm::Sha1);
    assert_eq!(a.digits, 6);
    assert_eq!(a.account_name, "alice@example.com");
    assert_eq!(a.issuer.as_deref(), Some("Example"));
    assert_eq!(a.secret, BASE32_NOPAD.encode(seed));
    assert_eq!(a.period, 30);
    assert_eq!(a.created_at, NOW);
    assert_eq!(a.updated_at, NOW);
    assert!(!a.id.is_empty());

    let b = &accounts[1];
    assert_eq!(b.otp_type, OtpType::Hotp);
    assert_eq!(b.algorithm, HashAlgorithm::Sha256);
    assert_eq!(b.digits, 8);
    assert_eq!(b.account_name, "bob");
    assert_eq!(b.issuer, None);
    assert_eq!(b.counter, 5);
    assert_eq!(
        b.secret,
        BASE32_NOPAD.encode(&[0x00, 0x01, 0x02, 0x03, 0x04])
    );
}

#[test]
fn url_encoded_data_param() {
    let seed = b"12345678901234567890";
    let p = build_otp_params(seed, "carol", "Svc", 1, 1, 2, None);
    let mut payload = Vec::new();
    len_field(1, &p, &mut payload);

    // Percent-encode the base64 data (as real Google Authenticator QR URIs do).
    let data = BASE64.encode(&payload);
    let encoded: String = data
        .chars()
        .map(|c| match c {
            '+' => "%2B".to_string(),
            '/' => "%2F".to_string(),
            '=' => "%3D".to_string(),
            other => other.to_string(),
        })
        .collect();
    let uri = format!("otpauth-migration://offline?data={encoded}");

    let accounts = parse_migration_uri(&uri, NOW).unwrap();
    assert_eq!(accounts.len(), 1);
    assert_eq!(accounts[0].account_name, "carol");
    assert_eq!(accounts[0].secret, BASE32_NOPAD.encode(seed));
}

#[test]
fn bad_scheme_errors() {
    assert!(parse_migration_uri("otpauth://totp/x?secret=AA", NOW).is_err());
}

#[test]
fn missing_data_errors() {
    assert!(parse_migration_uri("otpauth-migration://offline?foo=bar", NOW).is_err());
}
