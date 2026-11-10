# Packaged Windows service fixtures

This executable tests existing packaged Windows services with public fixtures.
It does not launch/install the app or widget, inspect existing credential entries,
use default application-data constructors, or contact an external endpoint.

```powershell
dotnet run --project tests/Otpeek.Windows.Fixtures/Otpeek.Windows.Fixtures.csproj `
  -c Release "-p:OtpeekPayloadDir=F:/isolated/payload" -- `
  F:/isolated/payload F:/isolated/public-qr-fixture.png
```

Use the independently generated public `qr-camera-fixture.png` described in
[Android QA](../../android/qa/README.md), generated from the public RFC seed by
`GenerateQrFixture.java`. Do not supply a personal QR image. Both arguments must
be absolute. The managed/native references come from that extracted MSIX payload.

The fixture uses CurrentUser DPAPI only to protect/unprotect a freshly generated
fixture VMK in a new UUID temporary directory. QuickOtpCodeProvider always receives
that directory explicitly and always sees a v2 vault, so its legacy PasswordVault
path is never called. Temporary files and listeners are disposed on completion.
The fixture does not change the logged-in user's installed app, stored vault or
credential entries. It does not invoke the widget diagnostic logger, which uses
the normal application data path.

Thirty-four assertions cover five QR image/parser/generation/BGRA/error cases,
six DPAPI/quick-surface cases, and WebDAV fetch/create/update/ETag/error/HEAD plus
the Rust-to-C# sync callback. Ten assertions check request path/auth invariants
across the HTTP cases. The server binds only IPv4 loopback and ephemeral ports;
credentials and data are public fixtures. The callback's uploaded ciphertext is
reopened with the same fixture VMK to verify the sync storage contract.

This does not establish desktop UI, screen capture, clipboard history, widget COM
activation, Windows lock-screen exposure, reboot recovery, installation, upgrade
or WACK certification results. Those still need the dedicated test desktop.
