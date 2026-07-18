OTPeek for Windows v2.0.1 (x64)
================================

Requirements
------------
- Windows 11, x64

Install
-------
1. Extract every file from this ZIP into one folder.
2. Open PowerShell in that folder.
3. Run:

   powershell -ExecutionPolicy Bypass -File .\Install-OTPeek.ps1

The installer verifies that the MSIX signature matches the included public
certificate before trusting it in Windows. The first installation shows a UAC
approval prompt so the certificate can be added to LocalMachine/TrustedPeople.
The certificate private key is never included.

If an unsigned OTPeek development registration is present, the installer replaces
that registration. Vault data remains in %LOCALAPPDATA%\Otpeek.

Widget
------
Open the Windows Widgets board, choose Add widgets, and add OTPeek. Widget and
file/protocol integration are available only from this installed MSIX build.

Source and updates
------------------
https://github.com/jiunbae/OTPeek
