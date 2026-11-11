# OTPeek Android

Kotlin/Compose shell over the existing Rust/UniFFI vault. Minimum API 26, target API 36, ARM64. Release application id is `com.otpeek.app`; local debug builds use `com.otpeek.app.debug` and contain no production signing configuration. No Play app has been reserved or published.

Implemented flow: password-protected vault, manual TOTP/HOTP registration (SHA1/256/512), CameraX + offline ZXing QR scan, Rust code generation, copy, deletion, optional authenticated Keystore VMK wrapping, encrypted v2 backup and v2/v1 restore through the Android document picker. No network permission, analytics, ads, widget, or sync UI.

## Build

Use JDK17, Android SDK platform36/build-tools35.0.0, NDK28.2.13676358, Rust1.94.0 with `aarch64-linux-android` std. The SDK defaults to `~/Library/Android/sdk`, Gradle downloads/cache to `~/.gradle`, and Rust to the shared rustup toolchain explicitly pinned by `build-rust.sh`. Cargo dependency downloads use `~/.cargo`. Versions remain pinned in the Gradle files, wrapper checksum, Rust script and Cargo lockfile. AVD userdata, Android user state, debug signing keys and QA evidence stay under ignored `.tools/`; compilation outputs stay under `core/target/` and Android build directories.

```sh
# One-time shared Rust setup (the default toolchain is unchanged):
rustup toolchain install 1.94.0 --profile minimal --target aarch64-linux-android
# From the repository root, using shared tools and project-specific outputs:
bash android/scripts/gradle-local.sh :app:assembleDebug :app:testDebugUnitTest
bash android/scripts/gradle-local.sh :app:assembleRelease :app:bundleRelease
```

Set JAVA_HOME to a JDK17 installation, or the launcher uses the retained `.tools/jdk` JDK17. Set ANDROID_SDK_ROOT (or ANDROID_HOME) to override the shared SDK and keep `android/local.properties` sdk.dir consistent with it. GRADLE_USER_HOME and CARGO_HOME can override their shared caches. `build-rust.sh` selects rustc, rustdoc and cargo from rustup1.94.0, builds Rust ARM64 release and a host metadata library, generates Kotlin from the matching library, and copies native output into `app/build/generated/`. No generated binding/native binaries are checked into sources. NDK macOS/Linux hosts are supported by the script.

Outputs: `android/app/build/outputs/apk/debug/app-debug.apk` (local debug signed), `apk/release/app-release-unsigned.apk`, and `bundle/release/app-release.aab` (unsigned). Configure production signing only in a separately authorized release task.

## Data and security behavior

- Vault crypto/OTP/parsing/backup stay in Rust; Android Keystore AES-GCM only wraps the VMK with an authentication-required, non-exportable device key. API30+ supports strong biometrics/device credential, API26–29 strong biometrics; vault password is the recovery path.
- The encrypted vault and wrapped VMK live under `noBackupFilesDir`. OS cloud and device-transfer backup are excluded. Explicit password-encrypted file backup is required before uninstall/device loss. Keystore keys are not portable. StrongBox availability is not required or assumed.
- Leaving the activity locks and drops the client. Secret/password fields are memory-only and are discarded on session changes. FLAG_SECURE blocks screen capture/recent-task previews. Errors and QR content are not logged.
- HOTP “Generate / consume” persists the current counter's code and increments the counter. Only the generated result can be copied. Rendering/copy do not advance it; overflow is rejected.
- Clipboard is sensitive and remains available across app switches. HOTP expires after 30 seconds; TOTP expires at the earlier of 30 seconds and code expiry. Cleanup checks an ownership UUID and preserves replacement clips. Background clipboard read restrictions can defer cleanup until focus returns; process termination can prevent it. The UI discloses this limitation. Explicit lock clears an accessible owned clip immediately.
- Restore validates a staging vault before atomically changing the active pointer. Wrong password/input failure retains the current vault. Merge preserves live duplicate IDs; replacement can regress HOTP counters and requires an explicit UI choice. Restore disables device authentication so the key can be enrolled again.
- Fresh v2 restore adopts the backup password as the vault password. Fresh v1 restore requires a new vault password. Export uses an independent backup password. External document providers can leave partial files on failed writes; no success is displayed until write/flush/close completes.
- Google migration is QR-by-QR with no guarantee of multi-QR batch completeness. Scan every QR; repeated exports can create duplicates because core parsing assigns new IDs. No migration preview/selection or new crypto/merge format is introduced.
- External files are limited to 8MiB and unauthenticated Argon2 costs to 128MiB/t6/p4. Decryption/authentication remains in Rust. Imported live accounts must have valid Base32, 6–8 digits, a positive UInt period and unique IDs. Empty imported names get a display label without changing stored data. These bounds can reject uncommon previously accepted files; no format is rewritten to bypass them.

## Fixture validation

Unit tests check untrusted backup cost/size preflight. Instrumentation tests use isolated fixture directories and public RFC/committed v2 data to check native loading, HOTP persistence, backup key independence, wrong-password safety, staging restore and Keystore wrapping/key-loss password recovery. The unattended wrapping test uses a fixture-only noninteractive key; production key creation always requires authentication. Interactive enrollment and OEM security behavior still need device QA.

```sh
bash android/scripts/gradle-local.sh :app:assembleDebug :app:assembleDebugAndroidTest
# Only the isolated OTPeek fixture emulator, separate ADB server at port5045:
bash android/scripts/adb-fixture.sh install -r android/app/build/outputs/apk/debug/app-debug.apk
bash android/scripts/adb-fixture.sh install -r android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
bash android/scripts/adb-fixture.sh shell am instrument -w \
  com.otpeek.app.debug.test/androidx.test.runner.AndroidJUnitRunner
```

The test helpers accept only emulator5660/5662, using explicit loopback TCP transports above ADB's default automatic emulator scan range. Set OTPEEK_EMULATOR_SERIAL=emulator-5662 for the 16KB fixture emulator. Do not run destructive cleanup or fixture commands against a user's device/vault.

16KB validation checks every bundled native ELF (Rust and JNA), APK zip alignment, AAB page alignment and runtime PAGE_SIZE=16384. A successful debug APK is not a substitute for release/R8 and physical-device verification. See [implementation plan](../docs/android/IMPLEMENTATION_PLAN.md) and [implementation validation](../docs/android/BUILD_VALIDATION.md) for actual results and remaining gates.

Verified local results: debug/release/R8/AAB builds, JVM 4 fixtures, API35 4KB and API36 16KB each 7 fixtures, all native ELF/ZIP/AAB alignment, and R8 native vault-create smoke passed. Lint has 0 errors and 12 warnings. Physical authentication, camera, SAF provider/recovery, older API and OEM behavior remain release gates.

Disk cleanup on 2026-10-27 retained only `otpeek-fixture-36-16k` (API36, ARM64, 16KB), matching targetSdk36 and native page-size QA. API26/30/34/35 images and their five AVDs were removed with the SDK tools; earlier test evidence remains preserved. Repeat testing on those APIs now requires reinstalling their images, so the earlier matrix is historical evidence. This emulator does not replace physical-device or Store certification checks.

The retained AVD is stopped after verification. To start it:

```sh
env ANDROID_USER_HOME="$PWD/.tools/android-user" \
  ANDROID_EMULATOR_HOME="$PWD/.tools/android-user" \
  ANDROID_AVD_HOME="$PWD/.tools/avd" \
  ANDROID_ADB_SERVER_PORT=5045 ADB_SERVER_SOCKET=tcp:127.0.0.1:5045 \
  "${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}/emulator/emulator" -avd otpeek-fixture-36-16k -port 5662 \
  -memory 3072 -cores 4 -gpu host -no-window -no-audio -no-snapshot -no-metrics
```

Follow-up QA (2026-10-17): API26/30/34/35/36 each passed 12 fixtures, Korean/200% text UI passed, system PIN and reboot/invalidation recovery, CameraX public QR and SAF v1/v2 reinstall recovery passed. The AAB-derived R8 universal APK also passed native/HOTP/process-death checks on 16KB. See [latest evidence and pending decisions](../docs/android/QA_20261017.md) and [disposable UI QA commands](qa/README.md). The user delegated policy decisions on 2026-10-25: the clipboard now survives app switches with a 30-second expiry attempt and own-clip cleanup. See [clipboard policy QA](../docs/android/CLIPBOARD_QA_20261025.md) for results and platform limits.
