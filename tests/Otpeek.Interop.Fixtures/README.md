# Packaged Windows interop fixtures

This console probe runs public RFC fixtures against `Otpeek.Interop.dll` and the
native `otpeek_ffi.dll` extracted from the actual candidate MSIX. It uses a new
UUID temporary directory and removes its fixture vaults on completion. It does
not start the installed app, use DPAPI, or open a user's vault.

After native MakeAppx unbundle/unpack validation, run on Windows x64:

```powershell
dotnet run --project tests/Otpeek.Interop.Fixtures/Otpeek.Interop.Fixtures.csproj `
  -c Release "-p:OtpeekPayloadDir=F:/isolated/payload" -- F:/isolated/payload
```

The payload argument must be absolute. Use the same directory for compilation and
execution so the managed binding and native DLL come from the same package.
The probe prints assertion names, never a VMK, password or account secret.

Eight assertions cover RFC TOTP/HOTP, display versus consume behavior, persisted
HOTP counter on password reopen, independent backup VMK, failed-import byte
preservation, live-duplicate merge and documented counter regression on replace.
These are eight assertions in one fixture executable, separate from the six
settings unit tests. They do not establish app UI, widget COM, DPAPI, QR capture,
clipboard, installation, upgrade or WACK certification results.
