# OTPeek — App Store submission (fastlane)

Automates build → sign → upload for the macOS and iOS App Store using an
**App Store Connect API key** (no interactive Apple ID / 2FA).

## One-time setup

1. Generate (or reuse) an App Store Connect API key:
   App Store Connect → **Users and Access → Integrations → App Store Connect API** →
   generate a key with **App Manager** role. Two `.p8` keys already exist on this
   machine under `~/.appstoreconnect/private_keys/`.
2. `cp apple/fastlane/.env.example apple/fastlane/.env` and fill in `ASC_KEY_ID`
   and `ASC_ISSUER_ID`. **Do not commit `.env` or the `.p8`.**
3. Create the App Store Connect record:
   ```bash
   cd apple && fastlane ios create_app
   ```

## Release

```bash
cd apple
fastlane mac release      # macOS: build, sign (team 728FW73BS8), upload
fastlane ios release      # iOS:   build, sign, upload to TestFlight
```

Signing is automatic (`-allowProvisioningUpdates` uses the API key to create the
distribution profiles, including the widget extension `com.otpeek.app.widget`).

`submit_for_review` is **off** by default — the build lands in App Store Connect /
TestFlight. Finish the human-only steps there (screenshots, privacy answers, age
rating, pricing, export compliance), then submit for review. See `../../docs/RELEASE.md`
for the listing copy and the pre-submission checklist.

## Notes
- First run may take a while — it builds the Rust core xcframework for all Apple slices.
- macOS App Store distribution requires the app to stay sandboxed + hardened-runtime
  (already configured in `project.yml`).
