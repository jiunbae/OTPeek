//! Base32 (RFC 4648) edge cases: lowercase, padding, spaces, invalid chars, empty.

use otp_core::{normalize_secret, validate_secret};

#[test]
fn lowercase_is_valid_and_uppercased() {
    assert!(validate_secret("jbswy3dpehpk3pxp"));
    assert_eq!(
        normalize_secret("jbswy3dpehpk3pxp").unwrap(),
        "JBSWY3DPEHPK3PXP"
    );
}

#[test]
fn padding_is_stripped() {
    // "MFRGG===" decodes; padding stripped on normalize.
    assert_eq!(normalize_secret("MFRGG===").unwrap(), "MFRGG");
    assert!(validate_secret("MFRGG==="));
}

#[test]
fn internal_spaces_stripped() {
    assert_eq!(
        normalize_secret("JBSW Y3DP EHPK 3PXP").unwrap(),
        "JBSWY3DPEHPK3PXP"
    );
    assert!(validate_secret("JBSW Y3DP"));
}

#[test]
fn mixed_case_and_whitespace() {
    assert_eq!(
        normalize_secret("  jBsW y3Dp\tehpk3pxp\n").unwrap(),
        "JBSWY3DPEHPK3PXP"
    );
}

#[test]
fn invalid_chars_rejected() {
    // 0, 1, 8, 9 are not in the base32 alphabet.
    assert!(!validate_secret("JBSW01889"));
    assert!(!validate_secret("!!!!"));
    assert!(normalize_secret("JBSW01889").is_err());
}

#[test]
fn empty_is_invalid() {
    assert!(!validate_secret(""));
    assert!(!validate_secret("   "));
    assert!(normalize_secret("").is_err());
}

#[test]
fn invalid_length_rejected() {
    // Length 1 (mod 8) is not a valid unpadded base32 length.
    assert!(!validate_secret("A"));
    assert!(!validate_secret("ABC"));
}
