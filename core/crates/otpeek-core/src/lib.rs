//! otpeek-core: pure OTP logic — algorithms, models, otpauth:// URIs, Google
//! Authenticator migration import. See docs/ARCHITECTURE.md §4 (frozen contract).

pub mod types;
pub use types::*;

mod algorithm;
mod base32;
mod migration;
mod uri;

use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum CoreError {
    #[error("invalid secret: {0}")]
    InvalidSecret(String),
    #[error("invalid uri: {0}")]
    InvalidUri(String),
    #[error("invalid parameter: {0}")]
    InvalidParameter(String),
}

/// RFC 6238 TOTP. Must pass the vectors in docs/SPEC.md.
pub fn generate_totp(
    secret_b32: &str,
    algorithm: HashAlgorithm,
    digits: u32,
    period: u32,
    unix_time_secs: i64,
) -> Result<String, CoreError> {
    algorithm::generate_totp(secret_b32, algorithm, digits, period, unix_time_secs)
}

/// RFC 4226 HOTP. Must pass the vectors in docs/SPEC.md.
pub fn generate_hotp(
    secret_b32: &str,
    algorithm: HashAlgorithm,
    digits: u32,
    counter: u64,
) -> Result<String, CoreError> {
    algorithm::generate_hotp(secret_b32, algorithm, digits, counter)
}

/// Convenience over an account; does NOT mutate the HOTP counter.
pub fn generate_code(account: &OtpAccount, unix_time_ms: i64) -> Result<OtpCode, CoreError> {
    algorithm::generate_code(account, unix_time_ms)
}

/// Parse a Google-Authenticator-compatible otpauth:// URI (SPEC.md §URI Format).
/// Assigns a fresh UUID id and sets created_at/updated_at to `now_ms`.
pub fn parse_otpauth_uri(uri: &str, now_ms: i64) -> Result<OtpAccount, CoreError> {
    uri::parse_otpauth_uri(uri, now_ms)
}

pub fn to_otpauth_uri(account: &OtpAccount) -> String {
    uri::to_otpauth_uri(account)
}

/// Parse otpauth-migration://offline?data=... (Google Authenticator export).
pub fn parse_migration_uri(uri: &str, now_ms: i64) -> Result<Vec<OtpAccount>, CoreError> {
    migration::parse_migration_uri(uri, now_ms)
}

/// RFC 4648 base32 validity (case-insensitive, '=' padding optional).
pub fn validate_secret(secret_b32: &str) -> bool {
    base32::validate_secret(secret_b32)
}

/// Normalize: uppercase, strip padding and whitespace. Errors if not valid base32.
pub fn normalize_secret(secret_b32: &str) -> Result<String, CoreError> {
    base32::normalize_secret(secret_b32)
}
