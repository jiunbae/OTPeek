# Multi-Device Setup & Sharing

How to register your OTP accounts once and use them on every device.

## How it works (30 seconds)

All your accounts live in one **end-to-end-encrypted vault**. Two keys matter:

- **Vault key (VMK)** — random 256-bit key that encrypts the vault. Each device
  can save it in its OS keystore (Keychain / DPAPI / Secret Service) to unlock
  the vault without re-entering the master password.
- **Master password** — used to join a new device and to unlock a vault where
  a saved key is unavailable. It unwraps the vault key using Argon2id.

The first device creates the vault and pushes it to the sync service. A new
device restores that vault using its master password. Each sync merges edits
and deletions. For HOTP, a merge keeps the higher counter. Two devices can
still use the same HOTP counter if they both advance before syncing. Use one
device for HOTP or sync between advances on different devices.

Pick ONE sync path per vault — don't mix iCloud and WebDAV for the same data.

## Path A — All-Apple devices: iCloud

Zero infrastructure. Works across devices signed into the **same Apple ID**
(CloudKit private database — it cannot share to a different Apple ID).

1. Device A: add your accounts → Settings → enable **Sync with iCloud**.
2. Device B: on first launch choose **Restore from iCloud** → enter the same
   master password. Done — the vault key is now in that device's Keychain.
3. With **Sync Automatically** enabled, the Apple apps sync after opening the
   vault, shortly after local changes, and every five minutes of unlocked app
   use. On iPhone and iPad, bring OTPeek to the foreground to pull changes.
   **Sync Now** is available in Settings for an immediate check.

## Path B — Cross-platform or self-hosted: WebDAV

WebDAV shares an encrypted vault between iPhone, iPad, Mac, Windows, and the
CLI. Use the same final HTTPS URL ending in `.otpvault` on each device. The
server needs to support conditional writes and return a strong, quoted ETag.
Enter the WebDAV login separately from the URL and the vault master password.

1. To put a local vault on WebDAV, use **Connect WebDAV** under Apple **Settings
   → Vault Sync**, or configure **WebDAV Sync** in Windows Settings. Sync once
   to create the remote vault.
2. On a new device, select **Restore from WebDAV** on Apple or **Join WebDAV
   vault** on Windows. Enter the same URL, server credentials, and the master
   password of the shared vault.
3. On a device with its own local vault, use **Join Existing WebDAV Vault** in
   Settings. OTPeek merges local records into the shared vault and keeps an
   encrypted recovery copy when adopting a different key. The original master
   password opens that copy. Records created independently with different IDs
   can appear as duplicates.
4. Enable **Sync Automatically** on Apple and scheduled WebDAV sync on
   Windows for ongoing updates. To switch an Apple vault from iCloud, sync it
   first and configure WebDAV on the Apple device with the latest accounts.
   Then join the WebDAV vault from the other devices.

First device (CLI example):

```bash
otpeek init                                   # choose your master password
otpeek add 'otpauth://totp/GitHub:me?secret=...&issuer=GitHub'
otpeek sync setup webdav https://nas.example.com/dav/otpeek-vault.otpvault --user june
otpeek sync now                               # first push
```

On a new CLI device:

```bash
otpeek restore https://nas.example.com/dav/otpeek-vault.otpvault --user june
otpeek sync setup webdav https://nas.example.com/dav/otpeek-vault.otpvault --user june
otpeek sync now
```

- `restore` creates a new local vault. If the destination already exists, use
  `OTPEEK_VAULT=<unused-path> otpeek restore …` or pass `--vault <unused-path>`
  before `restore`. The environment variable takes precedence. Use
  `import --merge` to add accounts from a backup to an existing vault.
- `restore` takes the WebDAV username from `--user`, `OTP_WEBDAV_USER`, or
  saved sync settings for the same URL, in that order. The WebDAV password comes
  from `OTP_WEBDAV_PASSWORD`, the system keystore entry for the URL and
  username, or a prompt. Use `OTPEEK_VAULT_PASSWORD` to supply the separate
  master password in headless use. When the username comes from matching sync
  settings, the CLI can also use credentials saved by older versions.
- Run `otpeek sync now` to sync from the CLI.

## Path C — No server at all: encrypted backup file

`export` produces a portable encrypted container (`.otpvault`) you can move by
AirDrop, USB, or any channel — it is safe to transit untrusted channels because
it is AES-256-GCM encrypted under a password you choose at export time
(independent from your master password).

```bash
otpeek export backup.otpvault                 # choose a new file and set a backup password
# move the file to the other device, then import to an existing vault:
otpeek import backup.otpvault --merge        # prompts for that backup password
```

Apps: Backup page → Export / Import. Even easier, `.otpvault` is a registered
file type: **double-click the file (macOS/Windows), or AirDrop/share it to an
Apple device, and the app opens directly into the import dialog**
(on Windows this requires the MSIX-installed app, not an unpackaged debug run) — type the
backup password, keep "merge" on, done. Export on Apple offers the share sheet,
so moving to a nearby device is export → AirDrop → tap. To create a new CLI
vault from the backup, run `otpeek restore backup.otpvault` at an unused
destination. Enter the password that protects that file. This becomes the
master password for the restored local vault.

All platforms read the same file, and the legacy v1 `.otpbackup` from the old
apps imports with `--legacy`.

Notes:
- This is a **snapshot** — later changes don't propagate. Use it for one-time
  moves, cold backups, or air-gapped machines; use Path A/B for continuous sync.
- `--merge` adds accounts you don't have and **restores ones you deleted by
  mistake**. Without `--merge`, the import replaces the existing vault contents
  with the backup contents.
- To move a single account instead of the whole vault: `otpeek qr <account>`
  (or the app's per-account QR) and scan it on the other device.

## Security notes

- iCloud/WebDAV servers, and anyone who copies a `.otpvault` file, only ever
  hold ciphertext. The protection level is your master/backup password run
  through Argon2id (64 MiB) — pick a strong one; it guards every device.
- A device with a saved vault key can still open the vault if you forget the
  master password. Export an encrypted backup with a new backup password
  to move those accounts into a new vault.
- `otpeek passwd` changes a known master password. Run `otpeek sync now` to
  publish the new password wrap. Other joined devices pick it up on sync.

## Choosing

| Situation | Use |
|---|---|
| Mac + iPhone, one Apple ID | Path A (iCloud) |
| Any Windows/Linux in the mix, or different user accounts | Path B (WebDAV) |
| One-time migration / cold backup / air-gapped box | Path C (encrypted file) |
| Move one account to a friend/another app | per-account QR (`otpeek qr`) |
