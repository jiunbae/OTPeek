# Platform Test Guide (v2 migration)

How to verify the shared-Rust-core migration on each platform. The Rust side is
already fully verified by CI-style tests; the platform shells need the checks
below. Work top-to-bottom per platform — each section starts with build
verification, then a functional pass.

## 0. Rust core & CLI (macOS or Linux — already verified, quick re-check)

```bash
cd core
cargo test --workspace        # expect: 77 tests, 0 failures
cargo build -p otpeek-cli --release
```

Functional smoke (isolated vault; no keyring/prompt needed):

```bash
export OTPEEK_VAULT=/tmp/otp-test/vault.otpvault
export OTPEEK_VAULT_PASSWORD='test-master-pw'
OTP=core/target/release/otpeek

$OTP init
$OTP add 'otpauth://totp/GitHub:me@example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub'
$OTP list
$OTP code github            # 6-digit code
$OTP code github --watch    # live countdown; Ctrl-C to exit
OTPEEK_BACKUP_PASSWORD='bk-pw' $OTP export /tmp/otp-test/backup.otpvault
$OTP rm github --yes
OTPEEK_BACKUP_PASSWORD='bk-pw' $OTP import /tmp/otp-test/backup.otpvault --merge   # resurrects
```

Real-world (keyring) mode: unset both env vars, run `otpeek init` — it prompts for
a master password and stores the vault key in the OS keystore (macOS Keychain /
Secret Service). Subsequent commands must NOT prompt.

WebDAV sync (needs a WebDAV server, e.g. Nextcloud):

```bash
$OTP sync setup webdav https://host/remote.php/dav/files/you/otpeek-vault.otpvault --user you
$OTP sync now               # first push
# second machine: otpeek restore <same-url>  → enter master password → otpeek list
```

## 1. macOS / iOS

Prereqs: full Xcode 15+ selected (`xcode-select -p` should point into Xcode.app,
not CommandLineTools), XcodeGen, iOS Rust targets:

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
apple/scripts/build-core.sh          # builds XCFramework + Swift bindings
cd apple && xcodegen generate
xcodebuild -project Otpeek.xcodeproj -scheme Otpeek-macOS build CODE_SIGNING_ALLOWED=NO
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
- [ ] iCloud sync (needs signing team + CloudKit container `iCloud.com.otpeek.app`
      provisioned in the developer portal): enable on device A, add account,
      sync; device B "Restore from iCloud" with master password → same accounts;
      edit on both sides → newest edit wins after both sync
- [ ] Keychain access group matches your team prefix (widget can read the VMK —
      if the widget shows an unlock error, reconcile the access-group string in
      both entitlements files with your Team ID)

## 2. Windows

Prereqs: VS 2022 (.NET Desktop + Windows App SDK), .NET 8 SDK, Rust MSVC:

```powershell
rustup target add x86_64-pc-windows-msvc
dotnet restore Otpeek.Windows.sln
dotnet build windows/Otpeek.App/Otpeek.App.csproj -p:Platform=x64
```

The unpackaged x64 app is also compiled on every pull request by the Windows CI job.
MSIX packaging, Widget COM registration, and runtime behavior still require a Windows
11 machine and the manual checks below.

Before testing Start-menu identity, protocols, file associations, or the widget, register
the development package (Developer Mode must be enabled):

```powershell
./windows/scripts/package-msix.ps1 -Mode Dev -Platforms x64
Get-AppxPackage -Name Otpeek
```

Launching `Otpeek.exe` directly is not a substitute: the Widget Host discovers the COM
provider only from the installed package manifest. If registration fails with `0x80070005`
against an orphan below `WindowsApps\Deleted`, restart Windows and retry before changing
the OTPeek manifest or certificate identity.

Verified on a Windows 11 x64 workstation on 2026-07-18:

- `dotnet build windows/Otpeek.App/Otpeek.App.csproj -c Release -p:Platform=x64`
  completed with 0 errors and staged `otpeek_ffi.dll` beside the app.
- `dotnet build windows/Otpeek.Widget/Otpeek.Widget.csproj -c Release -p:Platform=x64`
  completed with 0 errors and staged the same native library beside the widget provider.
- The final unsigned x64 MSIX bundle completed with 0 errors. Unpacking it confirmed the
  app and widget executables, native Rust DLL, responsive widget template, COM/widget
  manifest registration, and light/dark icon and preview assets.
- `Otpeek.Widget.exe --diagnostics` exited 0, and cross-process COM activation returned
  the WinRT provider while the server remained alive. The installed provider read the real
  20-account vault and reported `visibleEntryCount=8, iconEntryCount=7`; the unsupported or
  missing icon used the initial fallback.
- All 6 `Otpeek.Core.Tests` tests and all 77 shared Rust workspace tests passed on Windows.
- The Release app reached its main window and remained responsive in the logged-in desktop
  session; the startup smoke test covered account-editor XAML construction, first-page
  navigation, title-bar branding, initial empty/locked state, and the first-run password
  dialog.
- The orphaned legacy `OtpAuthenticator` directory was removed and the Dev package was
  registered from `%LOCALAPPDATA%\Otpeek.DevPackage`. `Get-AppxPackage -Name Otpeek`
  reports `Status=Ok`; the installed manifest contains the widget extension and matching
  COM class, and the WidgetService process was restarted. Complete the visual Widget Board
  checks below in the logged-in desktop session.
- After replacing or re-registering the loose Dev package, restart both `Widgets.exe` and
  `WidgetService.exe` before reopening the board. A host process that predates registration
  can retain a stale app-extension catalog and hide OTPeek even though the package reports
  `Status=Ok`.
- The branded multi-resolution `app.ico` is used by the tray icon. Left-click opens the rich
  WinUI surface with cached favicons and a one-second countdown. Right-click uses the native
  Win32 menu for immediate response; it is rebuilt from the already-open vault on every open,
  displays an ellipsized label plus right-aligned OTP and remaining time, and does not create a
  Window or timer. Selecting an account forces one final fresh generation before copying.
- Three non-fatal `MSB3277` reference warnings remain because
  `ZXing.Net.Bindings.Windows.Compatibility 0.16.14` requires
  `System.Drawing.Common 9.0.10` while the application targets .NET 8.

- [x] Interop project's MSBuild target runs cargo and stages `otpeek_ffi.dll` into
      the App output dir (check `bin/x64/Debug/.../otpeek_ffi.dll` exists)
- [ ] If bindings drift from otpeek-ffi: re-run `windows/scripts/generate-bindings.ps1`
- [x] App launches; `[DllImport("otpeek_ffi")]` resolves (no DllNotFoundException)
- [ ] Fresh start: master-password creation dialog → empty list
- [ ] Upgrade path: with a real v1 profile (`%LOCALAPPDATA%\Otpeek\accounts.dat`),
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
- [ ] Widget (Win11 widgets board) can be added after the Dev/MSIX package is registered
- [ ] Widget small size shows one compact code with Copy/previous/next and no clipped progress
      or Refresh footer; medium shows up to five and large shows up to eight live codes;
      clicking any row copies that account's fresh code
- [ ] Widget rows show cached issuer favicons when available and fall back to initials only
      for missing or unsupported images; no instructional/count summary consumes row space
- [ ] Tray uses the branded shield icon; left-click opens the rich live surface with favicon
      fallbacks and a one-second countdown, while right-click immediately opens a native menu
      with ellipsized labels and right-aligned OTP plus remaining time; reopening refreshes the
      displayed values, and selecting a row after a TOTP boundary copies the fresh code
- [ ] Widget empty/error states remain visible instead of terminating the provider; inspect
      `%LOCALAPPDATA%\Otpeek\widget.log` for COM activation and refresh diagnostics
- [ ] Known intentional drops: OneDrive/Google Drive sync, account Notes field,
      last-used ordering — confirm nothing else went missing

## 3. Cross-platform compatibility (the point of v2)

- [ ] Export a backup on macOS → import on Windows and via CLI → identical codes
      at the same instant (and vice versa)
- [ ] CLI and macOS app pointed at the SAME WebDAV vault stay consistent:
      add on CLI (`otpeek sync now`) → sync in app → account appears
- [ ] HOTP account: generate on two devices alternately → counters never reuse
      after sync (counter takes the max)

## Where to report

Anything failing on Windows/Xcode is expected to be small integration breakage
(WS-D/WS-E were built without those toolchains). Paste the exact compiler or
runtime error back into a Claude Code session in this repo — `docs/ARCHITECTURE.md`
has the full contract to fix against.
