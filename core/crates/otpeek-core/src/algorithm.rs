//! RFC 4226 (HOTP) / RFC 6238 (TOTP) implementations.
//!
//! The dynamic-truncation offset is taken from the LAST byte of the HMAC output
//! (`hmac[len - 1] & 0x0F`), which generalizes the SHA1-specific `hmac[19]`
//! formula in docs/SPEC.md to SHA256/SHA512.

use crate::base32;
use crate::types::{HashAlgorithm, OtpAccount, OtpCode, OtpType};
use crate::CoreError;
use hmac::{Hmac, Mac};
use sha1::Sha1;
use sha2::{Sha256, Sha512};

fn compute_hmac(algorithm: HashAlgorithm, key: &[u8], msg: &[u8]) -> Result<Vec<u8>, CoreError> {
    macro_rules! mac {
        ($hash:ty) => {{
            let mut mac = <Hmac<$hash>>::new_from_slice(key)
                .map_err(|_| CoreError::InvalidSecret("invalid HMAC key length".to_string()))?;
            mac.update(msg);
            Ok(mac.finalize().into_bytes().to_vec())
        }};
    }

    match algorithm {
        HashAlgorithm::Sha1 => mac!(Sha1),
        HashAlgorithm::Sha256 => mac!(Sha256),
        HashAlgorithm::Sha512 => mac!(Sha512),
    }
}

/// RFC 4226 dynamic truncation: offset from the last byte, 31-bit extraction,
/// modulo 10^digits, zero-padded to `digits` characters.
fn dynamic_truncate(hmac: &[u8], digits: u32) -> Result<String, CoreError> {
    if !(1..=9).contains(&digits) {
        return Err(CoreError::InvalidParameter(format!(
            "digits must be between 1 and 9, got {digits}"
        )));
    }
    let last = hmac
        .last()
        .ok_or_else(|| CoreError::InvalidSecret("empty HMAC output".to_string()))?;
    let offset = (last & 0x0f) as usize;
    if offset + 4 > hmac.len() {
        return Err(CoreError::InvalidSecret(
            "HMAC output too short for truncation".to_string(),
        ));
    }
    let binary = ((u32::from(hmac[offset]) & 0x7f) << 24)
        | (u32::from(hmac[offset + 1]) << 16)
        | (u32::from(hmac[offset + 2]) << 8)
        | u32::from(hmac[offset + 3]);
    let modulo = 10u64.pow(digits);
    let code = u64::from(binary) % modulo;
    Ok(format!("{:0width$}", code, width = digits as usize))
}

/// RFC 4226 HOTP.
pub fn generate_hotp(
    secret_b32: &str,
    algorithm: HashAlgorithm,
    digits: u32,
    counter: u64,
) -> Result<String, CoreError> {
    let normalized = base32::normalize_secret(secret_b32)?;
    let key = base32::decode(&normalized)?;
    let mac = compute_hmac(algorithm, &key, &counter.to_be_bytes())?;
    dynamic_truncate(&mac, digits)
}

/// RFC 6238 TOTP.
pub fn generate_totp(
    secret_b32: &str,
    algorithm: HashAlgorithm,
    digits: u32,
    period: u32,
    unix_time_secs: i64,
) -> Result<String, CoreError> {
    if period == 0 {
        return Err(CoreError::InvalidParameter(
            "period must be greater than 0".to_string(),
        ));
    }
    let counter = unix_time_secs.div_euclid(i64::from(period)) as u64;
    generate_hotp(secret_b32, algorithm, digits, counter)
}

/// Generate a code over an account. Does NOT mutate the HOTP counter.
pub fn generate_code(account: &OtpAccount, unix_time_ms: i64) -> Result<OtpCode, CoreError> {
    match account.otp_type {
        OtpType::Totp => {
            let period = if account.period == 0 {
                30
            } else {
                account.period
            };
            let unix_time_secs = unix_time_ms.div_euclid(1000);
            let code = generate_totp(
                &account.secret,
                account.algorithm,
                account.digits,
                period,
                unix_time_secs,
            )?;
            let period_ms = i64::from(period) * 1000;
            let valid_from = unix_time_ms.div_euclid(period_ms) * period_ms;
            let valid_until = valid_from + period_ms;
            Ok(OtpCode {
                code,
                valid_from,
                valid_until,
            })
        }
        OtpType::Hotp => {
            let code = generate_hotp(
                &account.secret,
                account.algorithm,
                account.digits,
                account.counter,
            )?;
            Ok(OtpCode {
                code,
                valid_from: unix_time_ms,
                valid_until: i64::MAX,
            })
        }
    }
}
