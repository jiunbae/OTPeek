# OTPeek — Windows (WinUI 3)

The Windows app is a thin WinUI 3 shell over the shared Rust core (`core/crates/otpeek-ffi`).
All OTP algorithms, the encrypted vault, backup and sync live in Rust and are consumed
through generated C# bindings.

## Projects

| Project | Framework | Role |
|---|---|---|
| `Otpeek.Interop` | `net8.0` | UniFFI-generated C# bindings (`Generated/otp.cs`) + native `otpeek_ffi.dll` packaging. No WinUI. |
| `Otpeek.Core` | `netstandard2.1;net8.0;net8.0-windows` | App-preference models + `SettingsService` + platform-service interfaces. No OTP logic. |
| `Otpeek.Core.Windows` | `net8.0-windows` | `OtpClientService` (wraps `OtpClient`), `WebDavSyncBackend`, DPAPI `SecureStorageService`, `LegacyMigrationService`, QR/clipboard/screen-capture. |
| `Otpeek.App` | `net8.0-windows` (WinUI 3) | UI shell, ViewModels, tray. |
| `Otpeek.Widget` | `net8.0-windows` | Widget COM host; reads the vault via `OtpClient.openWithKey` (DPAPI VMK) + `codesAt`. No WinUI, no Argon2. |

## Data layout (`%LOCALAPPDATA%\Otpeek\`)

- `vault.otpvault` — the single end-to-end-encrypted vault (AES-256-GCM under the VMK).
- `vmk.bin` — the 32-byte Vault Master Key, DPAPI-protected (`DataProtectionScope.CurrentUser`).
- `settings.dat` — app preferences (DPAPI). The WebDAV password is DPAPI-protected inside it.
- `accounts.dat` (legacy) → renamed to `accounts.dat.migrated` after first-run migration.

## Build order

The .NET build depends on the native library, so build in this order:

1. **Rust toolchain** — install via <https://rustup.rs>, then add the Windows targets you build for:
   ```powershell
   rustup target add x86_64-pc-windows-msvc      # x64
   rustup target add aarch64-pc-windows-msvc      # ARM64
   rustup target add i686-pc-windows-msvc         # x86 (optional)
   ```
2. **Native core** — this happens automatically as part of the .NET build: the
   `Otpeek.Interop` project runs
   `cargo build -p otpeek-ffi --profile <dev|release> --target <triple>` and stages
   `otpeek_ffi.dll` into every consumer's output. You can also build it manually:
   ```powershell
   cargo build -p otpeek-ffi --release --target x86_64-pc-windows-msvc
   ```
   If cargo is not on `PATH` **and** no prebuilt `otpeek_ffi.dll` exists, the build fails
   with an actionable error (it never silently ships without the native library).
3. **.NET solution**
   ```powershell
   dotnet build Otpeek.Windows.sln -c Debug -p:Platform=x64
   # or open Otpeek.Windows.sln in Visual Studio 2022 (17.8+)
   ```

## Regenerating the C# bindings

`windows/Otpeek.Interop/Generated/otp.cs` is **committed** — it is platform-independent
C#. Regenerate it only when the frozen FFI surface (`core/crates/otpeek-ffi/src/lib.rs`) changes:

```powershell
pwsh windows/scripts/generate-bindings.ps1        # debug cdylib
pwsh windows/scripts/generate-bindings.ps1 -Profile release
```

The generator is `uniffi-bindgen-cs` **v0.10.0+v0.29.4** (NordSecurity, matching uniffi 0.29).
Generation config (public access modifier, `Uniffi.Otpeek` namespace) lives in
`windows/Otpeek.Interop/uniffi.toml`. Commit the regenerated file.

## Sync (WebDAV)

`WebDavSyncBackend` implements the generated `SyncBackend` foreign trait using `HttpClient`
(synchronous `Send`, Basic auth, ETag / `If-Match` / `If-None-Match: *`). It stores a single
file `otpeek-vault.otpvault` under the configured collection URL. Configure it in
**Settings → WebDAV Sync**; the password is DPAPI-protected in `settings.dat`.

## Notes

- Widgets display codes without authentication by design (same as v1).
- Clipboard auto-clear timeout is configurable; there is no cryptographic guarantee of wipe.
