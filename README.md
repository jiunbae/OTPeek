# OTP Authenticator

A cross-platform OTP (One-Time Password) authenticator supporting TOTP and HOTP.
All logic lives in a **shared Rust core**; each platform keeps a native shell:
SwiftUI + WidgetKit on Apple, WinUI 3 on Windows, and a standalone `otp` CLI for
Linux/macOS.

## Features

- **TOTP/HOTP**: RFC 6238 / RFC 4226 compliant (SHA1, SHA256, SHA512; 6–8 digits)
- **End-to-end-encrypted vault**: single canonical store — AES-256-GCM payload,
  Argon2id-wrapped master key; platform keystores (Keychain / DPAPI / Secret
  Service) hold only the vault key, never the secrets
- **Sync**: encrypted-blob sync with pluggable backends — **iCloud (CloudKit)**
  on Apple, **WebDAV** everywhere (Nextcloud etc.); LWW merge with tombstones
- **QR Import**: camera scan, screen capture, image files, plus Google
  Authenticator migration QR (`otpauth-migration://`)
- **Folders & Favorites**, click-to-copy, system tray / menu bar, widgets
- **Backup & Restore**: portable encrypted `.otpvault` containers (legacy v1
  `.otpbackup` import supported)

## Platforms

| Platform | Shell | Status | Min Version |
|----------|-------|--------|-------------|
| Windows | WinUI 3 | ✅ | Windows 10 1809+ |
| macOS | SwiftUI + menu bar + widget | ✅ | macOS 14.0+ |
| iOS | SwiftUI + widget | ✅ | iOS 17.0+ |
| Linux / macOS CLI | `otp` binary | ✅ | — |

## Project Structure

```
OTPWidget/
├── core/                       # Rust workspace — ALL logic lives here
│   └── crates/
│       ├── otp-core/          # TOTP/HOTP, otpauth:// URIs, GA migration
│       ├── otp-vault/         # encrypted vault container v2, v1 import
│       ├── otp-sync/          # sync engine, merge rules, WebDAV backend
│       ├── otp-ffi/           # UniFFI facade (Swift / C# bindings)
│       └── otp-cli/           # `otp` command-line client
│
├── apple/                      # SwiftUI shells (macOS/iOS) + widget
│   ├── scripts/build-core.sh  # builds XCFramework + Swift bindings
│   └── Generated/             # uniffi-generated Swift (build output)
│
├── windows/                    # WinUI 3 shell + widget
│   ├── OtpAuthenticator.Interop/  # uniffi-generated C# + native lib packaging
│   └── scripts/generate-bindings.ps1
│
└── docs/
    ├── ARCHITECTURE.md        # v2 architecture & API contract (start here)
    ├── SPEC.md                # OTP algorithm spec + RFC test vectors
    ├── DATA_FORMAT.md         # data model semantics
    └── BACKUP_FORMAT.md       # legacy v1 backup format (import-only)
```

## Build Instructions

### Prerequisites (all platforms)

- **Rust** (stable) — https://rustup.rs

### Rust core & CLI

```bash
cd core
cargo test --workspace          # full test suite (RFC vectors, vault, sync, CLI)
cargo build -p otp-cli --release
./target/release/otp init       # create a vault
./target/release/otp add 'otpauth://totp/GitHub:me?secret=JBSWY3DPEHPK3PXP&issuer=GitHub'
./target/release/otp code github --copy
```

Vault: `~/.local/share/otp-auth/vault.otpvault` (override with `$OTP_VAULT`).
The vault key is kept in the OS keystore; headless environments can use
`$OTP_VAULT_PASSWORD` (and `$OTP_BACKUP_PASSWORD` for export/import).
Configure sync: `otp sync setup webdav <url> --user <name>`, then `otp sync now`.

### Apple (macOS / iOS)

Requires Xcode 15+ and XcodeGen (`brew install xcodegen`), plus iOS Rust targets:

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
apple/scripts/build-core.sh     # Rust → XCFramework + Swift bindings
cd apple && xcodegen generate && open OtpAuthenticator.xcodeproj
```

- macOS: `OtpAuthenticator-macOS` scheme → My Mac → Cmd+R
- iOS: `OtpAuthenticator-iOS` scheme → Simulator → Cmd+R

iCloud sync requires the `iCloud.com.otpauthenticator` CloudKit container on
your signing team.

### Windows

Requires Visual Studio 2022 (.NET Desktop + Windows App SDK), .NET 8 SDK, and
Rust with the MSVC target:

```powershell
rustup target add x86_64-pc-windows-msvc
# Interop project builds the Rust core automatically via MSBuild targets
dotnet restore OtpAuthenticator.Windows.sln
dotnet build windows/OtpAuthenticator.App/OtpAuthenticator.App.csproj -p:Platform=x64
```

To regenerate C# bindings after changing `otp-ffi`: `windows/scripts/generate-bindings.ps1`.

## Multi-Device Setup

Register once, use everywhere — full guide: **[docs/SYNC.md](docs/SYNC.md)**.

- **All-Apple (same Apple ID)**: enable iCloud Sync on the first device; other
  devices pick "Restore from iCloud" and enter the master password once.
- **Cross-platform / self-hosted**: point every device at the same WebDAV URL
  (`otp sync setup webdav <url> --user <u>`, then `otp restore <url>` on new
  devices). The server only ever stores an encrypted blob.
- **No server**: `otp export backup.otpvault` produces a portable encrypted
  container — AirDrop/copy it anywhere and `otp import --merge` on the other
  device. Same file works on Windows, Apple, and the CLI.

The master password is only typed when a device joins; afterwards each device
unlocks silently via its OS keystore and syncs merge automatically.

## Security Model

- Account secrets exist only inside the encrypted vault (AES-256-GCM, random
  256-bit vault master key) and in process memory of an unlocked client.
- The vault master key is wrapped by Argon2id(master password) — 64 MiB, t=3 —
  for sync/recovery, and stored in the platform keystore for password-less
  local unlock. Widgets never run the KDF.
- Sync backends only ever see encrypted bytes.
- See `docs/ARCHITECTURE.md` §14 for the full notes and tradeoffs (e.g. widget
  code visibility, clipboard).

## Documentation

- [Architecture & API contract](docs/ARCHITECTURE.md)
- [OTP Algorithm Specification](docs/SPEC.md)
- [Data Format Specification](docs/DATA_FORMAT.md)
- [Legacy Backup Format (v1, import-only)](docs/BACKUP_FORMAT.md)

## License

MIT License - See [LICENSE](LICENSE) for details.

## Contributing

1. Fork the repository
2. Create feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit changes (`git commit -m 'Add AmazingFeature'`)
4. Push to branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request
