//! RFC 4226 (HOTP) and RFC 6238 (TOTP) test vectors, including RFC 6238
//! Appendix B vectors for SHA1/SHA256/SHA512.

use data_encoding::BASE32_NOPAD;
use otp_core::{generate_hotp, generate_totp, HashAlgorithm};

fn b32(seed: &[u8]) -> String {
    BASE32_NOPAD.encode(seed)
}

const SHA1_SEED: &[u8] = b"12345678901234567890";
const SHA256_SEED: &[u8] = b"12345678901234567890123456789012";
const SHA512_SEED: &[u8] = b"1234567890123456789012345678901234567890123456789012345678901234";

#[test]
fn hotp_rfc4226_vectors() {
    let secret = b32(SHA1_SEED);
    let expected = [
        "755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871",
        "520489",
    ];
    for (counter, code) in expected.iter().enumerate() {
        let got = generate_hotp(&secret, HashAlgorithm::Sha1, 6, counter as u64).unwrap();
        assert_eq!(&got, code, "HOTP counter {counter}");
    }
}

#[test]
fn totp_sha1_vectors() {
    let secret = b32(SHA1_SEED);
    let cases = [
        (59_i64, "94287082"),
        (1111111109, "07081804"),
        (1111111111, "14050471"),
        (1234567890, "89005924"),
        (2000000000, "69279037"),
        (20000000000, "65353130"),
    ];
    for (time, code) in cases {
        let got = generate_totp(&secret, HashAlgorithm::Sha1, 8, 30, time).unwrap();
        assert_eq!(&got, code, "TOTP SHA1 t={time}");
    }
}

#[test]
fn totp_sha256_vectors() {
    let secret = b32(SHA256_SEED);
    let cases = [
        (59_i64, "46119246"),
        (1111111109, "68084774"),
        (1111111111, "67062674"),
        (1234567890, "91819424"),
        (2000000000, "90698825"),
        (20000000000, "77737706"),
    ];
    for (time, code) in cases {
        let got = generate_totp(&secret, HashAlgorithm::Sha256, 8, 30, time).unwrap();
        assert_eq!(&got, code, "TOTP SHA256 t={time}");
    }
}

#[test]
fn totp_sha512_vectors() {
    let secret = b32(SHA512_SEED);
    let cases = [
        (59_i64, "90693936"),
        (1111111109, "25091201"),
        (1111111111, "99943326"),
        (1234567890, "93441116"),
        (2000000000, "38618901"),
        (20000000000, "47863826"),
    ];
    for (time, code) in cases {
        let got = generate_totp(&secret, HashAlgorithm::Sha512, 8, 30, time).unwrap();
        assert_eq!(&got, code, "TOTP SHA512 t={time}");
    }
}

#[test]
fn totp_default_six_digits() {
    // Google Authenticator style: JBSWY3DPEHPK3PXP at time 0 with SHA1/6 digits.
    let got = generate_totp("JBSWY3DPEHPK3PXP", HashAlgorithm::Sha1, 6, 30, 0).unwrap();
    assert_eq!(got.len(), 6);
    assert!(got.chars().all(|c| c.is_ascii_digit()));
}

#[test]
fn period_zero_is_error() {
    assert!(generate_totp("JBSWY3DPEHPK3PXP", HashAlgorithm::Sha1, 6, 0, 0).is_err());
}
