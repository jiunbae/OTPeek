# Shared Resources

This directory contains resources shared across all platforms.

## Directory Structure

```
shared/
├── icons/              # App icons (all sizes)
├── test-vectors/       # OTP test data
└── localization/       # Translation files
```

## Icons

Platform-specific icon requirements:

### Windows
- `icon.ico` - Multi-resolution icon (16, 32, 48, 256)
- `Square44x44Logo.png`
- `Square150x150Logo.png`

### macOS
- `AppIcon.icns` - macOS icon set

### iOS
- `AppIcon.appiconset/` - iOS icon set (all required sizes)

## Localization

Translation files in JSON format:

```json
{
  "app_name": "OTPeek",
  "add_account": "Add Account",
  "scan_qr": "Scan QR Code",
  ...
}
```

Supported languages:
- `en.json` - English (default)
- `ko.json` - Korean
- `ja.json` - Japanese
