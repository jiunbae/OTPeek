<div align="center">

<img src="assets/icon.png" width="120" alt="OTPeek icon" />

# OTPeek

**Your 2FA codes at a glance — copy in one tap.**

A cross-platform OTP authenticator with a home-screen / desktop **widget** on every
platform, powered by a single **shared Rust core**.

<br/>

![Windows](https://img.shields.io/badge/Windows-WinUI%203-0078D6?logo=windows&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-SwiftUI-000000?logo=apple&logoColor=white)
![iOS](https://img.shields.io/badge/iOS-WidgetKit-000000?logo=apple&logoColor=white)
![CLI](https://img.shields.io/badge/CLI-Linux%20%7C%20macOS-4EAA25?logo=gnubash&logoColor=white)
<br/>
![Rust](https://img.shields.io/badge/core-Rust-DEA584?logo=rust&logoColor=white)
![TOTP / HOTP](https://img.shields.io/badge/2FA-TOTP%20%7C%20HOTP-5A5AAD)
![E2E encrypted](https://img.shields.io/badge/vault-AES--256--GCM-2E7D32)
![License](https://img.shields.io/badge/license-MIT-blue)

</div>

---

## Why OTPeek

- 👁️ **At a glance** — your codes live in a native widget (iOS/macOS Home Screen,
  Windows Widgets Board, menu bar / system tray). No app launch, no digging.
- ⚡ **One-tap copy** — glance, tap, paste. That's the whole flow.
- 🦀 **One brain, native shells** — all OTP/vault/sync logic is a shared Rust core;
  each platform keeps a thin, fully-native UI (SwiftUI, WinUI 3).
- 🔒 **Yours only** — end-to-end-encrypted vault; sync backends only ever see
  ciphertext.

## Features

- **TOTP / HOTP** — RFC 6238 / RFC 4226 compliant (SHA1, SHA256, SHA512; 6–8 digits)
- **End-to-end-encrypted vault** — AES-256-GCM payload, Argon2id-wrapped master key;
  platform keystores (Keychain / DPAPI / Secret Service) hold only the vault key,
  never the secrets
- **Sync** — encrypted-blob sync with pluggable backends: **iCloud (CloudKit)** on
  Apple, **WebDAV** everywhere (Nextcloud etc.); last-writer-wins merge with tombstones
- **QR import** — camera scan, screen capture, image files, plus Google Authenticator
  migration QR (`otpauth-migration://`)
- **Folders & favorites**, click-to-copy, system tray / menu bar, and widgets
- **Backup & restore** — portable encrypted `.otpvault` containers (legacy v1
  `.otpbackup` import supported)

## Platforms

| Platform | Shell | Widget | Status | Min version |
|----------|-------|:------:|:------:|-------------|
| Windows | WinUI 3 | ✅ | ✅ | Windows 10 1809+ |
| macOS | SwiftUI + menu bar | ✅ | ✅ | macOS 14.0+ |
| iOS | SwiftUI | ✅ | ✅ | iOS 17.0+ |
| Linux / macOS CLI | `otpeek` binary | — | ✅ | — |

## Architecture

```
OTPeek/
├── core/                        # Rust workspace — ALL logic lives here
│   └── crates/
│       ├── otpeek-core/          # TOTP/HOTP, otpauth:// URIs, GA migration
│       ├── otpeek-vault/         # encrypted vault container v2, v1 import
│       ├── otpeek-sync/          # sync engine, merge rules, WebDAV backend
│       ├── otpeek-ffi/           # UniFFI facade (Swift / C# bindings)
│       └── otpeek-cli/           # `otpeek` command-line client
│
├── apple/                       # SwiftUI shells (macOS/iOS) + widget
│   ├── scripts/build-core.sh    # builds XCFramework + Swift bindings
│   └── Generated/               # uniffi-generated Swift (build output)
│
├── windows/                     # WinUI 3 shell + widget
│   ├── Otpeek.Interop/          # uniffi-generated C# + native lib packaging
│   └── scripts/generate-bindings.ps1
│
└── docs/                        # architecture, specs, data formats
```

The Rust core is exposed to Swift and C# through [UniFFI](https://mozilla.github.io/uniffi-rs/);
neither app reimplements any OTP, crypto, or sync logic.

## Quick Start

> **Prerequisite (all platforms):** [Rust](https://rustup.rs) (stable).

<details>
<summary><b>🦀 Rust core & CLI</b></summary>

```bash
cd core
cargo test --workspace          # RFC vectors, vault, sync, CLI
cargo build -p otpeek-cli --release
sudo cp target/release/otpeek /usr/local/bin/   # optional: install on PATH

otpeek init                     # create a vault
otpeek add 'otpauth://totp/GitHub:me?secret=JBSWY3DPEHPK3PXP&issuer=GitHub'
otpeek code github --copy
```

Vault: `~/.local/share/otpeek/vault.otpvault` (override with `$OTPEEK_VAULT`).
The vault key lives in the OS keystore; headless environments can use
`$OTPEEK_VAULT_PASSWORD` (and `$OTPEEK_BACKUP_PASSWORD` for export/import).
Configure sync: `otpeek sync setup webdav <url> --user <name>`, then `otpeek sync now`.

</details>

<details>
<summary><b>🍎 Apple (macOS / iOS)</b></summary>

Requires **full Xcode 15+** (Command Line Tools alone cannot build the app or the
XCFramework — check `xcode-select -p` points into `Xcode.app`), [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and the iOS Rust targets:

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
apple/scripts/build-core.sh     # Rust → XCFramework + Swift bindings
cd apple && xcodegen generate && open Otpeek.xcodeproj
```

- macOS: `Otpeek-macOS` scheme → My Mac → ⌘R
- iOS: `Otpeek-iOS` scheme → Simulator → ⌘R

iCloud sync requires the `iCloud.com.otpeek.app` CloudKit container on your signing team.

</details>

<details>
<summary><b>🪟 Windows</b></summary>

Requires Visual Studio 2022 (.NET Desktop + Windows App SDK), .NET 8 SDK, and Rust
with the MSVC target:

```powershell
rustup target add x86_64-pc-windows-msvc
# The Interop project builds the Rust core automatically via MSBuild targets.
dotnet restore Otpeek.Windows.sln
dotnet build windows/Otpeek.App/Otpeek.App.csproj -p:Platform=x64
```

Regenerate C# bindings after changing `otpeek-ffi`: `windows/scripts/generate-bindings.ps1`.
`.otpvault` double-click association registers only when installed as an MSIX package.

</details>

## Multi-Device Setup

Register once, use everywhere — full guide: **[docs/SYNC.md](docs/SYNC.md)**.

- **All-Apple (same Apple ID)** — enable iCloud Sync on the first device; other
  devices pick "Restore from iCloud" and enter the master password once.
- **Cross-platform / self-hosted** — point every device at the same WebDAV URL
  (`otpeek sync setup webdav <url> --user <u>`, then `otpeek restore <url>` on new
  devices). The server only ever stores an encrypted blob.
- **No server** — `otpeek export backup.otpvault` produces a portable encrypted
  container. Double-click (Windows/macOS) or share via AirDrop (Apple) and the app
  opens straight into import — enter the backup password and you're done.

The master password is only typed when a device joins; afterwards each device unlocks
silently via its OS keystore and merges syncs automatically.

## Security Model

- Account secrets exist only inside the encrypted vault (AES-256-GCM, random 256-bit
  master key) and in the process memory of an unlocked client.
- The vault master key is wrapped by Argon2id (master password) — 64 MiB, t=3 — for
  sync/recovery, and stored in the platform keystore for password-less local unlock.
  **Widgets never run the KDF.**
- Sync backends only ever see encrypted bytes.
- See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §14 for the full notes and
  tradeoffs (widget code visibility, clipboard).

## Documentation

- [Architecture & API contract](docs/ARCHITECTURE.md) — start here
- [Releasing & store distribution](docs/RELEASE.md)
- [OTP Algorithm Specification](docs/SPEC.md)
- [Data Format Specification](docs/DATA_FORMAT.md)
- [Legacy Backup Format (v1, import-only)](docs/BACKUP_FORMAT.md)

## License

[MIT](LICENSE) © OTPeek

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request
