//! Google Authenticator export: `otpauth-migration://offline?data=<base64(protobuf)>`.
//!
//! The protobuf schema (well-known `MigrationPayload`) is decoded by hand:
//!
//! ```text
//! message MigrationPayload {
//!   repeated OtpParameters otp_parameters = 1;
//!   // (version = 2, batch_size = 3, batch_index = 4, batch_id = 5 — ignored)
//! }
//! message OtpParameters {
//!   bytes  secret    = 1;   // RAW bytes -> re-encoded to base32
//!   string name      = 2;
//!   string issuer    = 3;
//!   Algorithm algorithm = 4; // 1=SHA1, 2=SHA256, 3=SHA512
//!   DigitCount digits   = 5; // 1=six, 2=eight
//!   OtpType type        = 6; // 1=hotp, 2=totp
//!   int64  counter    = 7;
//! }
//! ```

use crate::base32;
use crate::types::{HashAlgorithm, OtpAccount, OtpType};
use crate::uri::percent_decode;
use crate::CoreError;
use data_encoding::{BASE64, BASE64URL, BASE64URL_NOPAD, BASE64_NOPAD};
use url::Url;
use uuid::Uuid;

#[derive(Default)]
struct OtpParameters {
    secret: Vec<u8>,
    name: String,
    issuer: String,
    algorithm: u64,
    digits: u64,
    otp_type: u64,
    counter: u64,
}

/// Read a base-128 varint starting at `*pos`. Advances `*pos`.
fn read_varint(buf: &[u8], pos: &mut usize) -> Result<u64, CoreError> {
    let mut result: u64 = 0;
    let mut shift: u32 = 0;
    loop {
        let byte = *buf
            .get(*pos)
            .ok_or_else(|| CoreError::InvalidUri("truncated varint".to_string()))?;
        *pos += 1;
        result |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Ok(result);
        }
        shift += 7;
        if shift >= 64 {
            return Err(CoreError::InvalidUri("varint overflow".to_string()));
        }
    }
}

/// Read a length-delimited field's bytes, advancing `*pos` past them.
fn read_len_delimited<'a>(buf: &'a [u8], pos: &mut usize) -> Result<&'a [u8], CoreError> {
    let len = read_varint(buf, pos)? as usize;
    let end = pos
        .checked_add(len)
        .filter(|end| *end <= buf.len())
        .ok_or_else(|| CoreError::InvalidUri("length-delimited field out of bounds".to_string()))?;
    let slice = &buf[*pos..end];
    *pos = end;
    Ok(slice)
}

/// Skip a field with the given wire type.
fn skip_field(buf: &[u8], pos: &mut usize, wire_type: u64) -> Result<(), CoreError> {
    match wire_type {
        0 => {
            read_varint(buf, pos)?;
        }
        1 => {
            *pos = pos
                .checked_add(8)
                .filter(|p| *p <= buf.len())
                .ok_or_else(|| CoreError::InvalidUri("truncated 64-bit field".to_string()))?;
        }
        2 => {
            read_len_delimited(buf, pos)?;
        }
        5 => {
            *pos = pos
                .checked_add(4)
                .filter(|p| *p <= buf.len())
                .ok_or_else(|| CoreError::InvalidUri("truncated 32-bit field".to_string()))?;
        }
        other => {
            return Err(CoreError::InvalidUri(format!(
                "unsupported protobuf wire type: {other}"
            )))
        }
    }
    Ok(())
}

fn parse_otp_parameters(buf: &[u8]) -> Result<OtpParameters, CoreError> {
    let mut params = OtpParameters::default();
    let mut pos = 0;
    while pos < buf.len() {
        let tag = read_varint(buf, &mut pos)?;
        let field = tag >> 3;
        let wire_type = tag & 0x07;
        match (field, wire_type) {
            (1, 2) => params.secret = read_len_delimited(buf, &mut pos)?.to_vec(),
            (2, 2) => {
                params.name =
                    String::from_utf8_lossy(read_len_delimited(buf, &mut pos)?).into_owned()
            }
            (3, 2) => {
                params.issuer =
                    String::from_utf8_lossy(read_len_delimited(buf, &mut pos)?).into_owned()
            }
            (4, 0) => params.algorithm = read_varint(buf, &mut pos)?,
            (5, 0) => params.digits = read_varint(buf, &mut pos)?,
            (6, 0) => params.otp_type = read_varint(buf, &mut pos)?,
            (7, 0) => params.counter = read_varint(buf, &mut pos)?,
            _ => skip_field(buf, &mut pos, wire_type)?,
        }
    }
    Ok(params)
}

fn parse_migration_payload(buf: &[u8]) -> Result<Vec<OtpParameters>, CoreError> {
    let mut out = Vec::new();
    let mut pos = 0;
    while pos < buf.len() {
        let tag = read_varint(buf, &mut pos)?;
        let field = tag >> 3;
        let wire_type = tag & 0x07;
        if field == 1 && wire_type == 2 {
            let msg = read_len_delimited(buf, &mut pos)?;
            out.push(parse_otp_parameters(msg)?);
        } else {
            skip_field(buf, &mut pos, wire_type)?;
        }
    }
    Ok(out)
}

/// Decode base64 tolerating standard/url-safe alphabets and optional padding.
fn decode_base64(data: &str) -> Result<Vec<u8>, CoreError> {
    let cleaned: String = data.chars().filter(|c| !c.is_whitespace()).collect();
    for enc in [BASE64, BASE64_NOPAD, BASE64URL, BASE64URL_NOPAD] {
        if let Ok(bytes) = enc.decode(cleaned.as_bytes()) {
            return Ok(bytes);
        }
    }
    Err(CoreError::InvalidUri("invalid base64 data".to_string()))
}

fn map_algorithm(value: u64) -> HashAlgorithm {
    match value {
        2 => HashAlgorithm::Sha256,
        3 => HashAlgorithm::Sha512,
        _ => HashAlgorithm::Sha1,
    }
}

fn map_digits(value: u64) -> u32 {
    match value {
        2 => 8,
        _ => 6,
    }
}

fn map_type(value: u64) -> OtpType {
    match value {
        1 => OtpType::Hotp,
        _ => OtpType::Totp,
    }
}

/// Extract a raw (still percent-encoded) query parameter value from the raw query
/// string. Avoids form decoding so `+` in base64 data is preserved.
fn raw_query_param(query: &str, name: &str) -> Option<String> {
    for pair in query.split('&') {
        if let Some((key, value)) = pair.split_once('=') {
            if key == name {
                return Some(value.to_string());
            }
        }
    }
    None
}

pub fn parse_migration_uri(uri: &str, now_ms: i64) -> Result<Vec<OtpAccount>, CoreError> {
    let parsed = Url::parse(uri).map_err(|e| CoreError::InvalidUri(format!("parse error: {e}")))?;
    if parsed.scheme() != "otpauth-migration" {
        return Err(CoreError::InvalidUri(format!(
            "expected otpauth-migration scheme, got {}",
            parsed.scheme()
        )));
    }

    let query = parsed
        .query()
        .ok_or_else(|| CoreError::InvalidUri("missing query".to_string()))?;
    let raw_data = raw_query_param(query, "data")
        .ok_or_else(|| CoreError::InvalidUri("missing data".to_string()))?;
    let data = percent_decode(&raw_data);
    let bytes = decode_base64(&data)?;
    let params_list = parse_migration_payload(&bytes)?;

    let mut accounts = Vec::with_capacity(params_list.len());
    for params in params_list {
        if params.secret.is_empty() {
            return Err(CoreError::InvalidSecret(
                "migration entry has empty secret".to_string(),
            ));
        }
        let secret = base32::encode(&params.secret);
        let issuer = if params.issuer.is_empty() {
            None
        } else {
            Some(params.issuer)
        };
        accounts.push(OtpAccount {
            id: Uuid::new_v4().to_string(),
            otp_type: map_type(params.otp_type),
            secret,
            issuer,
            account_name: params.name,
            algorithm: map_algorithm(params.algorithm),
            digits: map_digits(params.digits),
            period: 30,
            counter: params.counter,
            folder_id: None,
            is_favorite: false,
            sort_order: 0,
            icon: None,
            color: None,
            created_at: now_ms,
            updated_at: now_ms,
            deleted_at: None,
        });
    }
    Ok(accounts)
}
