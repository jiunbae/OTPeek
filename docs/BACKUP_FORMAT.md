# Backup Format Specification

> **Legacy (v1, import-only).** The live format is the v2 vault container defined in [ARCHITECTURE.md](ARCHITECTURE.md) §5.2. This v1 format is retained only so old backups can still be imported.

This document defines the backup/export format for cross-platform data portability.

## Overview

Backup files are encrypted JSON files that can be transferred between any supported platform (Windows, macOS, iOS).

## File Format

### Extension
`.otpbackup`

### Structure
```
[4 bytes]  Magic number: "OTPB" (0x4F545042)
[4 bytes]  Version: uint32 little-endian (current: 1)
[32 bytes] Salt for key derivation
[12 bytes] AES-GCM nonce
[16 bytes] AES-GCM authentication tag
[n bytes]  Encrypted payload (AES-256-GCM)
```

## Encryption

### Key Derivation
- **Algorithm**: PBKDF2-SHA256
- **Iterations**: 100,000
- **Salt**: 32 bytes random
- **Output**: 256-bit key

### Payload Encryption
- **Algorithm**: AES-256-GCM
- **Nonce**: 12 bytes random
- **Tag**: 16 bytes

## Decrypted Payload

The decrypted payload is a JSON object:

```json
{
  "version": 1,
  "exportedAt": "2024-01-01T12:00:00Z",
  "accounts": [
    {
      "type": "totp",
      "secret": "JBSWY3DPEHPK3PXP",
      "issuer": "GitHub",
      "accountName": "user@example.com",
      "algorithm": "SHA1",
      "digits": 6,
      "period": 30
    }
  ],
  "folders": [
    {
      "id": "660e8400-e29b-41d4-a716-446655440001",
      "name": "Work",
      "icon": "briefcase",
      "color": "#0078D4"
    }
  ]
}
```

### Payload Schema

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["version", "exportedAt", "accounts"],
  "properties": {
    "version": { "type": "integer", "const": 1 },
    "exportedAt": { "type": "string", "format": "date-time" },
    "accounts": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["type", "secret", "accountName"],
        "properties": {
          "type": { "type": "string", "enum": ["totp", "hotp"] },
          "secret": { "type": "string" },
          "issuer": { "type": "string" },
          "accountName": { "type": "string" },
          "algorithm": { "type": "string", "enum": ["SHA1", "SHA256", "SHA512"] },
          "digits": { "type": "integer" },
          "period": { "type": "integer" },
          "counter": { "type": "integer" },
          "folderId": { "type": "string" }
        }
      }
    },
    "folders": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["id", "name"],
        "properties": {
          "id": { "type": "string" },
          "name": { "type": "string" },
          "icon": { "type": "string" },
          "color": { "type": "string" }
        }
      }
    }
  }
}
```

## Security Considerations

1. **Password Strength**: Minimum 8 characters recommended
2. **Key Stretching**: 100,000 PBKDF2 iterations to slow brute-force attacks
3. **Authenticated Encryption**: AES-GCM provides both confidentiality and integrity
4. **Random Salt/Nonce**: Fresh random values for each backup

## Compatibility

### Import Sources
- OTPeek backup files (.otpbackup)
- Google Authenticator migration QR codes
- Plain otpauth:// URIs

### Export Targets
- OTPeek backup files (.otpbackup)
- Individual QR codes (otpauth:// URIs)

## Implementation Notes

### Windows (.NET)
```csharp
using System.Security.Cryptography;

// Key derivation
var key = Rfc2898DeriveBytes.Pbkdf2(password, salt, 100000, HashAlgorithmName.SHA256, 32);

// Encryption
using var aes = new AesGcm(key);
aes.Encrypt(nonce, plaintext, ciphertext, tag);
```

### Apple (Swift)
```swift
import CryptoKit

// Key derivation
let key = try PBKDF2<SHA256>.deriveKey(from: password, salt: salt, iterations: 100000, outputByteCount: 32)

// Encryption
let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
```
