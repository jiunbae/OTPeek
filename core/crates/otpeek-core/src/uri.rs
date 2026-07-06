//! otpauth:// URI parsing and serialization (Google Authenticator compatible).
//! See docs/SPEC.md §URI Format.

use crate::base32;
use crate::types::{HashAlgorithm, OtpAccount, OtpType};
use crate::CoreError;
use url::Url;
use uuid::Uuid;

/// Percent-decode a string. Unlike form decoding, `+` is left untouched.
pub(crate) fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hi = (bytes[i + 1] as char).to_digit(16);
            let lo = (bytes[i + 2] as char).to_digit(16);
            if let (Some(hi), Some(lo)) = (hi, lo) {
                out.push((hi * 16 + lo) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Percent-encode a string, encoding everything outside the RFC 3986 unreserved set.
fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for &b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn algorithm_str(algorithm: HashAlgorithm) -> &'static str {
    match algorithm {
        HashAlgorithm::Sha1 => "SHA1",
        HashAlgorithm::Sha256 => "SHA256",
        HashAlgorithm::Sha512 => "SHA512",
    }
}

fn parse_algorithm(value: &str) -> Result<HashAlgorithm, CoreError> {
    match value.to_ascii_uppercase().as_str() {
        "SHA1" => Ok(HashAlgorithm::Sha1),
        "SHA256" => Ok(HashAlgorithm::Sha256),
        "SHA512" => Ok(HashAlgorithm::Sha512),
        other => Err(CoreError::InvalidParameter(format!(
            "unsupported algorithm: {other}"
        ))),
    }
}

/// Split a decoded label into (issuer, account_name) per "Issuer:Account".
fn split_label(label: &str) -> (Option<String>, String) {
    match label.split_once(':') {
        Some((issuer, account)) => {
            let issuer = issuer.trim();
            let account = account.trim_start();
            let issuer = if issuer.is_empty() {
                None
            } else {
                Some(issuer.to_string())
            };
            (issuer, account.to_string())
        }
        None => (None, label.trim().to_string()),
    }
}

pub fn parse_otpauth_uri(uri: &str, now_ms: i64) -> Result<OtpAccount, CoreError> {
    let parsed = Url::parse(uri).map_err(|e| CoreError::InvalidUri(format!("parse error: {e}")))?;
    if parsed.scheme() != "otpauth" {
        return Err(CoreError::InvalidUri(format!(
            "expected otpauth scheme, got {}",
            parsed.scheme()
        )));
    }

    let otp_type = match parsed.host_str().map(|h| h.to_ascii_lowercase()).as_deref() {
        Some("totp") => OtpType::Totp,
        Some("hotp") => OtpType::Hotp,
        other => {
            return Err(CoreError::InvalidUri(format!(
                "unknown otp type: {}",
                other.unwrap_or("<none>")
            )))
        }
    };

    let raw_label = parsed.path().strip_prefix('/').unwrap_or(parsed.path());
    let label = percent_decode(raw_label);
    let (label_issuer, account_name) = split_label(&label);

    let mut secret: Option<String> = None;
    let mut issuer_param: Option<String> = None;
    let mut algorithm = HashAlgorithm::Sha1;
    let mut digits: u32 = 6;
    let mut period: u32 = 30;
    let mut counter: u64 = 0;

    for (key, value) in parsed.query_pairs() {
        match key.as_ref() {
            "secret" => secret = Some(value.into_owned()),
            "issuer" => {
                let v = value.into_owned();
                if !v.is_empty() {
                    issuer_param = Some(v);
                }
            }
            "algorithm" => algorithm = parse_algorithm(&value)?,
            "digits" => {
                digits = value
                    .parse()
                    .map_err(|_| CoreError::InvalidParameter(format!("invalid digits: {value}")))?
            }
            "period" => {
                period = value
                    .parse()
                    .map_err(|_| CoreError::InvalidParameter(format!("invalid period: {value}")))?
            }
            "counter" => {
                counter = value
                    .parse()
                    .map_err(|_| CoreError::InvalidParameter(format!("invalid counter: {value}")))?
            }
            _ => {}
        }
    }

    let secret = secret.ok_or_else(|| CoreError::InvalidUri("missing secret".to_string()))?;
    let secret = base32::normalize_secret(&secret)?;

    // issuer query parameter takes precedence over the label prefix.
    let issuer = issuer_param.or(label_issuer);

    Ok(OtpAccount {
        id: Uuid::new_v4().to_string(),
        otp_type,
        secret,
        issuer,
        account_name,
        algorithm,
        digits,
        period,
        counter,
        folder_id: None,
        is_favorite: false,
        sort_order: 0,
        icon: None,
        color: None,
        created_at: now_ms,
        updated_at: now_ms,
        deleted_at: None,
    })
}

pub fn to_otpauth_uri(account: &OtpAccount) -> String {
    let type_str = match account.otp_type {
        OtpType::Totp => "totp",
        OtpType::Hotp => "hotp",
    };

    let has_issuer = account.issuer.as_ref().is_some_and(|i| !i.is_empty());

    let label = if has_issuer {
        let issuer = account.issuer.as_deref().unwrap_or("");
        format!(
            "{}:{}",
            percent_encode(issuer),
            percent_encode(&account.account_name)
        )
    } else {
        percent_encode(&account.account_name)
    };

    let mut params: Vec<String> = Vec::new();
    // secret is normalized base32 (A-Z2-7 only) and needs no escaping.
    params.push(format!("secret={}", account.secret));
    if has_issuer {
        if let Some(issuer) = &account.issuer {
            params.push(format!("issuer={}", percent_encode(issuer)));
        }
    }
    params.push(format!("algorithm={}", algorithm_str(account.algorithm)));
    params.push(format!("digits={}", account.digits));
    match account.otp_type {
        OtpType::Totp => params.push(format!("period={}", account.period)),
        OtpType::Hotp => params.push(format!("counter={}", account.counter)),
    }

    format!("otpauth://{}/{}?{}", type_str, label, params.join("&"))
}
