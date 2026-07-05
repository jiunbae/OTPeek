# Platform Test Guide (v2 migration)

How to verify the shared-Rust-core migration on each platform. The Rust side is
already fully verified by CI-style tests; the platform shells need the checks
below. Work top-to-bottom per platform — each section starts with build
verification, then a functional pass.

## 0. Rust core & CLI (macOS or Linux — already verified, quick re-check)

```bash
cd core
cargo test --workspace        # expect: 77 tests, 0 failures
cargo build -p otp-cli --release
```

Functional smoke (isolated vault; no keyring/prompt needed):

```bash
export OTP_VAULT=/tmp/otp-test/vault.otpvault
export OTP_VAULT_PASSWORD='test-master-pw'
OTP=core/target/release/otp

$OTP init
$OTP add 'otpauth://totp/GitHub:me@example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub'
$OTP list
$OTP code github            # 6-digit code
$OTP code github --watch    # live countdown; Ctrl-C to exit
OTP_BACKUP_PASSWORD='bk-pw' $OTP export /tmp/otp-test/backup.otpvault
$OTP rm github --yes
OTP_BACKUP_PASSWORD='bk-pw' $OTP import /tmp/otp-test/backup.otpvault --merge   # resurrects
```

Real-world (keyring) mode: unset both env vars, run `otp init` — it prompts for
a master password and stores the vault key in the OS keystore (macOS Keychain /
Secret Service). Subsequent commands must NOT prompt.

WebDAV sync (needs a WebDAV server, e.g. Nextcloud):

```bash
$OTP sync setup webdav https://host/remote.php/dav/files/you/otp-vault.otpvault --user you
$OTP sync now               # first push
# second machine: otp restore <same-url>  → enter master password → otp list
```

## 1. macOS / iOS

Prereqs: full Xcode 15+ selected (`xcode-select -p` should point into Xcode.app,
not CommandLineTools), XcodeGen, iOS Rust targets:

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
apple/scripts/build-core.sh          # builds XCFramework + Swift bindings
cd apple && xcodegen generate
xcodebuild -project OtpAuthenticator.xcodeproj -scheme OtpAuthenticator-macOS build CODE_SIGNING_ALLOWED=NO
```

- [ ] `build-core.sh` completes: all 3 slices + `Frameworks/OtpCore.xcframework` + `Generated/otp.swift`
- [ ] macOS scheme builds; iOS scheme builds
- [ ] First launch (fresh): onboarding asks to create a master password; app opens empty
- [ ] First launch (upgrade from v1 data): migration screen appears, all legacy
      accounts survive with correct codes; legacy UserDefaults key renamed `migrated_*`
- [ ] Add account by QR scan and by manual entry; codes match another authenticator
- [ ] Kill & relaunch: NO password prompt (VMK from Keychain)
- [ ] Widget shows codes and updates across periods; add/delete in app reflects
      in widget without relaunch
- [ ] Menu bar popup works; click-to-copy works
- [ ] Backup export → file; import on a clean install restores accounts
- [ ] File association: double-click a `.otpvault` in Finder → app opens the
      import dialog; AirDrop the file from iPhone → same; export offers the
      share sheet; opening a file on a FRESH install routes to restore
- [ ] iCloud sync (needs signing team + CloudKit container `iCloud.com.otpauthenticator`
      provisioned in the developer portal): enable on device A, add account,
      sync; device B "Restore from iCloud" with master password → same accounts;
      edit on both sides → newest edit wins after both sync
- [ ] Keychain access group matches your team prefix (widget can read the VMK —
      if the widget shows an unlock error, reconcile the access-group string in
      both entitlements files with your Team ID)

## 2. Windows  ⚠️ never compiled yet — expect to fix small compile errors

Prereqs: VS 2022 (.NET Desktop + Windows App SDK), .NET 8 SDK, Rust MSVC:

```powershell
rustup target add x86_64-pc-windows-msvc
dotnet restore OtpAuthenticator.Windows.sln
dotnet build windows/OtpAuthenticator.App/OtpAuthenticator.App.csproj -p:Platform=x64
```

- [ ] Interop project's MSBuild target runs cargo and stages `otp_ffi.dll` into
      the App output dir (check `bin/x64/Debug/.../otp_ffi.dll` exists)
- [ ] If bindings drift from otp-ffi: re-run `windows/scripts/generate-bindings.ps1`
- [ ] App launches; `[DllImport("otp_ffi")]` resolves (no DllNotFoundException)
- [ ] Fresh start: master-password creation dialog → empty list
- [ ] Upgrade path: with a real v1 profile (`%LOCALAPPDATA%\OtpAuthenticator\accounts.dat`),
      migration prompt appears, accounts survive, legacy file renamed `.migrated`
- [ ] Add via QR (screen capture + image file) and manual entry; codes correct
- [ ] Restart: no password prompt (VMK via DPAPI `vmk.bin`)
- [ ] Tray popup, click-to-copy, folders, favorites
- [ ] Backup export/import (v2), legacy v1 `.otpbackup` import
- [ ] File association (after MSIX deploy): double-click a `.otpvault` in
      Explorer → app opens the import dialog (wrong password → friendly retry);
      opening a file on a FRESH install routes to restore; double-click while
      the app is already running doesn't spawn a broken second instance
- [ ] WebDAV settings section: configure server → Sync Now → vault file appears
      on the server; second machine syncs the same accounts
- [ ] Foreign-trait check: WebDAV sync with a WRONG password shows an auth error
      (exception marshalling through the FFI, not a crash)
- [ ] Widget (Win11 widgets board) shows codes
- [ ] Known intentional drops: OneDrive/Google Drive sync, account Notes field,
      last-used ordering — confirm nothing else went missing

## 3. Cross-platform compatibility (the point of v2)

- [ ] Export a backup on macOS → import on Windows and via CLI → identical codes
      at the same instant (and vice versa)
- [ ] CLI and macOS app pointed at the SAME WebDAV vault stay consistent:
      add on CLI (`otp sync now`) → sync in app → account appears
- [ ] HOTP account: generate on two devices alternately → counters never reuse
      after sync (counter takes the max)

## Where to report

Anything failing on Windows/Xcode is expected to be small integration breakage
(WS-D/WS-E were built without those toolchains). Paste the exact compiler or
runtime error back into a Claude Code session in this repo — `docs/ARCHITECTURE.md`
has the full contract to fix against.
