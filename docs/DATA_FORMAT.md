# Data Format Specification

This document defines the data formats used for storing OTP accounts to ensure cross-platform compatibility.

## Account Model

### Core Fields

| Field       | Type     | Required | Description |
|-------------|----------|----------|-------------|
| id          | UUID     | Yes      | Unique identifier |
| type        | string   | Yes      | "totp" or "hotp" |
| secret      | string   | Yes      | Base32-encoded secret key |
| issuer      | string   | No       | Service provider name |
| accountName | string   | Yes      | User account identifier |
| algorithm   | string   | No       | "SHA1" (default), "SHA256", "SHA512" |
| digits      | int      | No       | 6 (default), 7, or 8 |
| period      | int      | No       | TOTP period in seconds (default: 30) |
| counter     | long     | No       | HOTP counter (required for HOTP) |

### Metadata Fields

| Field       | Type     | Required | Description |
|-------------|----------|----------|-------------|
| folderId    | UUID     | No       | Parent folder ID |
| isFavorite  | bool     | No       | Favorite status |
| sortOrder   | int      | No       | Display order |
| createdAt   | datetime | No       | Creation timestamp (ISO 8601) |
| updatedAt   | datetime | No       | Last update timestamp (ISO 8601) |
| iconUrl     | string   | No       | Custom icon URL |
| color       | string   | No       | Custom color (hex format) |

## Folder Model

| Field       | Type     | Required | Description |
|-------------|----------|----------|-------------|
| id          | UUID     | Yes      | Unique identifier |
| name        | string   | Yes      | Folder display name |
| icon        | string   | No       | Icon identifier or emoji |
| color       | string   | No       | Color in hex format (#RRGGBB) |
| sortOrder   | int      | No       | Display order |

## JSON Schema

### Account

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["id", "type", "secret", "accountName"],
  "properties": {
    "id": { "type": "string", "format": "uuid" },
    "type": { "type": "string", "enum": ["totp", "hotp"] },
    "secret": { "type": "string", "pattern": "^[A-Z2-7]+=*$" },
    "issuer": { "type": "string" },
    "accountName": { "type": "string" },
    "algorithm": { "type": "string", "enum": ["SHA1", "SHA256", "SHA512"], "default": "SHA1" },
    "digits": { "type": "integer", "enum": [6, 7, 8], "default": 6 },
    "period": { "type": "integer", "minimum": 1, "default": 30 },
    "counter": { "type": "integer", "minimum": 0 },
    "folderId": { "type": "string", "format": "uuid" },
    "isFavorite": { "type": "boolean", "default": false },
    "sortOrder": { "type": "integer", "default": 0 },
    "createdAt": { "type": "string", "format": "date-time" },
    "updatedAt": { "type": "string", "format": "date-time" }
  }
}
```

### Example

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "type": "totp",
  "secret": "JBSWY3DPEHPK3PXP",
  "issuer": "GitHub",
  "accountName": "user@example.com",
  "algorithm": "SHA1",
  "digits": 6,
  "period": 30,
  "folderId": "660e8400-e29b-41d4-a716-446655440001",
  "isFavorite": true,
  "sortOrder": 0,
  "createdAt": "2024-01-01T00:00:00Z",
  "updatedAt": "2024-01-01T00:00:00Z"
}
```

## Storage

### Windows
- Location: `%LOCALAPPDATA%\Otpeek\`
- Accounts: `accounts.json` (encrypted)
- Settings: `settings.json`
- Secure data: Windows PasswordVault / DPAPI

### macOS / iOS
- Location: App Group container
- Accounts: Keychain Services (encrypted)
- Settings: UserDefaults
- Secure data: Keychain with access control

## Encryption

Account secrets are always stored encrypted using platform-native APIs:

- **Windows**: DPAPI (Data Protection API)
- **macOS/iOS**: Keychain Services with `kSecAttrAccessibleWhenUnlocked`

The encrypted data format is platform-specific and not interchangeable.
