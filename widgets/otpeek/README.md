# OTP Codes — BarShelf widget

Your [OTPeek](https://github.com/jiunbae/otpeek) TOTP codes in the macOS
menu bar via [BarShelf](https://github.com/Open330/barshelf), a scriptable
menu-bar widget platform.

Each account shows its service favicon, issuer/name, a live countdown ring,
and a one-tap copy that auto-clears the clipboard after 30s. Codes are read
from the OTPeek vault (`otpeek code … --json`) and are never logged or
cached to disk.

## Install

Requires the [`otpeek`](https://github.com/jiunbae/otpeek) CLI and a vault
unlocked via the Keychain (`otpeek unlock`).

```bash
bsf install https://github.com/jiunbae/otpeek/tree/main/widgets/otpeek
```

Or the deep link (BarShelf must be installed):

```text
barshelf://install?url=https%3A%2F%2Fgithub.com%2Fjiunbae%2Fotpeek%2Ftree%2Fmain%2Fwidgets%2Fotpeek
```
