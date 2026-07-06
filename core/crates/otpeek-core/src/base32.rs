//! RFC 4648 base32 helpers. Case-insensitive input; normalize to uppercase with
//! padding and whitespace stripped.

use crate::CoreError;
use data_encoding::BASE32_NOPAD;

/// Normalize a base32 secret: uppercase, strip whitespace and `=` padding.
/// Errors with `InvalidSecret` if the result is empty or not valid base32.
pub fn normalize_secret(secret_b32: &str) -> Result<String, CoreError> {
    let cleaned: String = secret_b32
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '=')
        .map(|c| c.to_ascii_uppercase())
        .collect();

    if cleaned.is_empty() {
        return Err(CoreError::InvalidSecret("empty secret".to_string()));
    }

    // Validate that the normalized form decodes as RFC 4648 base32.
    decode(&cleaned)?;
    Ok(cleaned)
}

/// `true` if the secret is valid base32 (after normalization).
pub fn validate_secret(secret_b32: &str) -> bool {
    normalize_secret(secret_b32).is_ok()
}

/// Decode an already-normalized (uppercase, unpadded) base32 string to bytes.
pub fn decode(normalized: &str) -> Result<Vec<u8>, CoreError> {
    BASE32_NOPAD
        .decode(normalized.as_bytes())
        .map_err(|e| CoreError::InvalidSecret(format!("invalid base32: {e}")))
}

/// Encode raw bytes to unpadded uppercase base32 (used by migration import).
pub fn encode(bytes: &[u8]) -> String {
    BASE32_NOPAD.encode(bytes)
}
