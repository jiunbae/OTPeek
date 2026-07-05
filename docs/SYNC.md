# Multi-Device Setup & Sharing

How to register your OTP accounts once and use them on every device.

## How it works (30 seconds)

All your accounts live in one **end-to-end-encrypted vault**. Two keys matter:

- **Vault key (VMK)** — random 256-bit key that encrypts the vault. Each device
  keeps it in its OS keystore (Keychain / DPAPI / Secret Service), so daily use
  never asks for a password.
- **Master password** — the thing you type ONCE per device to join. It unwraps
  the vault key via Argon2id. Anyone (or any server) without it sees only
  ciphertext.

So the flow is always the same: **first device creates the vault and pushes it
somewhere; every other device "restores" from there with the master password;
after that, everything merges automatically** (newest edit wins, deletions
propagate, HOTP counters never regress).

Pick ONE sync path per vault — don't mix iCloud and WebDAV for the same data.

## Path A — All-Apple devices: iCloud

Zero infrastructure. Works across devices signed into the **same Apple ID**
(CloudKit private database — it cannot share to a different Apple ID).

1. Device A: add your accounts → Settings → enable **iCloud Sync** → Sync Now.
2. Device B: on first launch choose **Restore from iCloud** → enter the same
   master password. Done — the vault key is now in that device's Keychain.
3. Edits on any device converge on the next sync.

## Path B — Cross-platform or self-hosted: WebDAV

Works everywhere (Windows, macOS, iOS, Linux CLI) and keeps you in control of
the server. Any WebDAV endpoint works: Nextcloud, Synology/QNAP NAS, Apache/
nginx WebDAV, etc. The server only ever stores an encrypted blob.

First device (CLI example):

```bash
otp init                                   # choose your master password
otp add 'otpauth://totp/GitHub:me?secret=...&issuer=GitHub'
otp sync setup webdav https://nas.example.com/dav/otp-vault.otpvault --user june
otp sync now                               # first push
```

Every other device:

```bash
otp restore https://nas.example.com/dav/otp-vault.otpvault   # asks master password
otp sync setup webdav https://nas.example.com/dav/otp-vault.otpvault --user june
otp sync now
```

- Windows app: Settings → WebDAV → same URL/user → restore flow.
- Sync anytime with `otp sync now` (CLI) or the Sync Now button (apps).

## Path C — No server at all: encrypted backup file

`export` produces a portable encrypted container (`.otpvault`) you can move by
AirDrop, USB, or any channel — it is safe to transit untrusted channels because
it is AES-256-GCM encrypted under a password you choose at export time
(independent from your master password).

```bash
otp export backup.otpvault                 # prompts for a backup password
# move the file to the other device, then:
otp import backup.otpvault --merge        # prompts for that backup password
```

Apps: Backup page → Export / Import. All platforms read the same file, and the
legacy v1 `.otpbackup` from the old apps imports with `--legacy`.

Notes:
- This is a **snapshot** — later changes don't propagate. Use it for one-time
  moves, cold backups, or air-gapped machines; use Path A/B for continuous sync.
- `--merge` adds accounts you don't have and **restores ones you deleted by
  mistake**; without `--merge` the import replaces your vault entirely.
- To move a single account instead of the whole vault: `otp qr <account>`
  (or the app's per-account QR) and scan it on the other device.

## Security notes

- iCloud/WebDAV servers, and anyone who copies a `.otpvault` file, only ever
  hold ciphertext. The protection level is your master/backup password run
  through Argon2id (64 MiB) — pick a strong one; it guards every device.
- The master password is needed only when a device **joins** (and for password
  changes). Day-to-day unlock is silent via the OS keystore.
- Losing the master password does not lock out already-joined devices (they
  hold the vault key), but no NEW device can join and the remote blob becomes
  unrecoverable — change the password from a joined device (`otp passwd`),
  which takes effect everywhere on the next sync.

## Choosing

| Situation | Use |
|---|---|
| Mac + iPhone, one Apple ID | Path A (iCloud) |
| Any Windows/Linux in the mix, or different user accounts | Path B (WebDAV) |
| One-time migration / cold backup / air-gapped box | Path C (encrypted file) |
| Move one account to a friend/another app | per-account QR (`otp qr`) |
