# Releasing OTPeek

End-to-end distribution guide for the App Store, the Microsoft Store, and the CLI.
CI (`.github/workflows/ci.yml`) builds all three platforms on every PR — a release
starts from a green `main`.

> **Accounts & secrets you must supply** — none of these live in the repo:
> - Apple Developer Program membership (Team `728FW73BS8`) + App Store Connect app record
> - Distribution certificates / provisioning (Xcode "Automatic signing" can manage these)
> - Microsoft Partner Center registration + a reserved app identity
> - A code-signing certificate for sideloaded MSIX (Store submissions are re-signed by MS)

---

## Versioning

Keep every surface on the same marketing version before tagging a release.

| Surface | Where | Field |
|---------|-------|-------|
| Apple (app + widget) | `apple/project.yml` | `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` |
| Windows | `windows/Otpeek.App/Package.appxmanifest` | `<Identity Version="x.y.z.0">` |
| Rust core / CLI | `core/Cargo.toml` (`workspace.package.version`) | `version` |

The App Store rejects a build whose extension `CFBundleShortVersionString` differs
from the parent app — bump the app and widget together.

---

## Apple — App Store (macOS & iOS)

Requires **full Xcode 15+** and the iOS Rust targets
(`rustup target add aarch64-apple-ios aarch64-apple-ios-sim`).

1. **Build the Rust core & regenerate the project**
   ```bash
   apple/scripts/build-core.sh
   cd apple && xcodegen generate
   ```

2. **Archive** (repeat per scheme: `Otpeek-macOS`, `Otpeek-iOS`)
   ```bash
   xcodebuild -project apple/Otpeek.xcodeproj \
     -scheme Otpeek-macOS -configuration Release \
     -archivePath build/Otpeek-macOS.xcarchive archive
   ```

3. **Export & upload** using the committed [`apple/ExportOptions.plist`](../apple/ExportOptions.plist)
   ```bash
   xcodebuild -exportArchive \
     -archivePath build/Otpeek-macOS.xcarchive \
     -exportOptionsPlist apple/ExportOptions.plist \
     -exportPath build/export
   xcrun altool --upload-app -f build/export/*.pkg -t macos \
     --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"   # or use Transporter
   ```
   (iOS exports an `.ipa`; use `-t ios`.)

4. **App Store Connect**: attach the build, fill the listing (below), submit for review.

### Pre-submission checklist
- [ ] `PrivacyInfo.xcprivacy` is accurate — we ship it declaring **no data collection**,
      no tracking, and the UserDefaults + file-timestamp required-reason APIs. Re-audit
      against the [Apple required-reason API list](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files)
      if you add dependencies. A matching manifest should also cover the widget extension.
- [ ] Entitlements: App Sandbox + Hardened Runtime are on; keychain group, app group
      `group.com.otpeek.app`, and the `iCloud.com.otpeek.app` CloudKit container exist on the team.
- [ ] `ITSAppUsesNonExemptEncryption = false` is set (it is) — standard crypto only.
- [ ] Screenshots for every required device class.

---

## Windows — Microsoft Store (MSIX)

Requires VS 2022 (.NET Desktop + Windows App SDK), .NET 8 SDK, Rust + MSVC target.

1. **Reserve the identity** in Partner Center, then paste the values it gives you into
   `windows/Otpeek.App/Package.appxmanifest` (the committed values are placeholders):
   ```xml
   <Identity Name="<PartnerCenter-Name>" Publisher="<PartnerCenter-Publisher-CN>" Version="1.0.1.0" />
   <Properties><PublisherDisplayName><Your seller name></PublisherDisplayName></Properties>
   ```
   Also replace the placeholder `mp:PhoneIdentity PhoneProductId` GUID.

2. **Package for the Store** (unsigned upload bundle; the Store re-signs):
   ```powershell
   ./windows/scripts/package-msix.ps1 -Mode Store -Platforms x64,arm64
   ```
   → produces a `.msixupload` under `windows/Otpeek.App/AppPackages/`.

3. **Submit** the `.msixupload` in Partner Center → fill the listing (below) → submit.

### Sideload / direct-install build
```powershell
./windows/scripts/package-msix.ps1 -Mode Sideload -Platforms x64 `
    -CertPath .\otpeek.pfx -CertPassword (Read-Host -AsSecureString)
```
To keep a non-exportable private key in the current-user certificate store, pass
`-CertThumbprint <thumbprint>` instead of `-CertPath`.

Install the resulting `.msix` with `Add-AppxPackage`. The `.otpvault` file
association and the widget provider register only from an installed MSIX, not from
an unpackaged `dotnet run`.

GitHub sideload releases include the signed bundle, its public `.cer`, and
`Install-OTPeek.ps1`. The installer verifies that the package signer matches that
certificate before requesting UAC approval to trust it under
`Cert:\LocalMachine\TrustedPeople`; the signing private key must never be included
in release artifacts.

For local widget and shell-integration testing without creating a signing certificate,
enable Windows Developer Mode and register the loose package:

```powershell
./windows/scripts/package-msix.ps1 -Mode Dev -Platforms x64
```

This mode is for development only. Store and sideload releases still use the signing and
identity flows above.

---

## CLI (Linux / macOS)

Prebuilt binaries are published to **GitHub Releases** by
[`.github/workflows/release-cli.yml`](../.github/workflows/release-cli.yml), which
builds `otpeek` on native runners for four targets — `x86_64`/`aarch64` ×
`unknown-linux-gnu`/`apple-darwin` — and attaches a `.tar.gz` + `.sha256` for each,
plus `install.sh`.

**Cut a release:**

```bash
# 1. bump core/Cargo.toml workspace.package.version to match the tag, land it on main
# 2. tag and push — this triggers the release workflow
git tag v2.0.0
git push origin v2.0.0
```

The workflow creates/updates the `v2.0.0` Release and uploads the assets. Re-run it
against an existing tag from the Actions tab ("Run workflow" → enter the tag) if a
build needs redoing. Once assets exist, the one-liner works:

```bash
curl -fsSL https://raw.githubusercontent.com/jiunbae/OTPeek/main/install.sh | sh
```

Linux runtime deps: `libdbus-1` (keystore) + `libxcb` (clipboard) — bundled on any
desktop distro; headless boxes need `libdbus-1-3 libxcb1`.

**Build from source** instead:

```bash
cd core
cargo build -p otpeek-cli --release
# distribute target/release/otpeek — or `cargo install --path crates/otpeek-cli`
```

---

## Deep links (`otpeek://`)

Both apps register the custom scheme (Apple `CFBundleURLTypes`, Windows
`windows.protocol`). Supported forms:

| URL | Action |
|-----|--------|
| `otpeek://` | Open / foreground the app |
| `otpeek://totp/GitHub:me?secret=…&issuer=GitHub` | Add an account (an `otpauth://` URI with the scheme swapped) |
| `otpeek://hotp/…` | Add a counter-based account |
| `otpeek://add?uri=<url-encoded otpauth:// URI>` | Add the wrapped account |

The account is added only when the vault is unlocked. The **standard `otpauth://`
scheme is deliberately NOT re-branded** — it is the industry Key URI format emitted
by every 2FA provider's QR code and must keep working across all apps.

---

## Store listing copy

Reuse verbatim across stores; trim to each store's length limits.

**Name:** `OTPeek`
**Subtitle / short description:** `2FA codes at a glance — copy in one tap`

**Description:**
> OTPeek keeps your two-factor codes one glance away. A native widget on your Home
> Screen, desktop, and menu bar shows your OTP codes without opening the app — glance,
> tap, copy, done.
>
> • TOTP & HOTP (RFC 6238 / 4226), 6–8 digits, SHA-1/256/512
> • Home-screen / desktop widgets on every platform
> • End-to-end-encrypted vault (AES-256-GCM); your secrets never leave your devices in the clear
> • Sync via iCloud or any WebDAV server — the server only ever stores ciphertext
> • Import by QR scan, screenshot, image, or Google Authenticator export
> • Encrypted `.otpvault` backup & restore
>
> No accounts. No ads. No tracking. Your codes are yours.

**Keywords:** `2FA, OTP, authenticator, TOTP, two-factor, verification code, widget, MFA`

**Privacy:** Collects no data. Link a privacy policy stating the same before submission.
