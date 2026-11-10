# Windows clipboard ownership fixtures

Run against the extracted current MSIX's `Otpeek.Core.Windows.dll` on Windows:

```powershell
dotnet run --project tests/Otpeek.Clipboard.Fixtures/Otpeek.Clipboard.Fixtures.csproj `
  -c Release "-p:OtpeekPayloadDir=F:/isolated/current-payload"
```

The fixture uses the service's internal transport constructor and real WinRT
DataPackage/ClipboardContentOptions objects. All contents remain in memory. It
never calls the default service constructor or the system Clipboard APIs and
never reads or replaces the user's clipboard.

Assertions cover no-copy/no-access, official no-history/no-roaming options,
flush/read, explicit owned clear, another app's identical-text replacement,
expiry after replacement, cancellation by a newer copy, still-owned expiry,
explicit timer cancellation and rejected write behavior. This tests the changed
service logic against the real packaged assembly. It does not certify OS clipboard
history, other applications, the separate Win32 widget copy path or desktop UI.

Ownership is a best-effort marker check immediately before Clear. Windows does
not provide an atomic compare-and-clear through this API, so another process can
still race between the read and the clear. Expiry cannot be guaranteed after
process exit or when Windows denies background clipboard access. These are not
changed by the fixture transport.
