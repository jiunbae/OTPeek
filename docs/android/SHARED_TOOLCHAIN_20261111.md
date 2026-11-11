# Shared Android toolchain migration — 2026-11-11

Scope: Tend request `req_18e6e44284b41450_2a`. Authorized cleanup and shared toolchain migration only; commit locally, no push or PR. No Apple/Windows implementation, app policy, cryptography or vault format changes.

## Commands and observed results

- `bash android/scripts/build-rust.sh`: exit 0; Rust ARM64 release, host metadata library and matching UniFFI Kotlin binding generated with pinned Rust 1.94.0.
- `bash android/scripts/gradle-local.sh :app:assembleDebug :app:assembleDebugAndroidTest :app:testDebugUnitTest :app:assembleRelease :app:bundleRelease :app:lintDebug`: `BUILD SUCCESSFUL in 5m 40s`; 132 tasks, 129 executed, 3 up-to-date. Six JVM tests passed; lint reported 0 errors and 12 warnings (dependency update / ChromeOS ABI advisories).
- `python3 android/scripts/verify-native.py android/app/build/outputs/apk/debug/app-debug.apk` and the corresponding `apk/release/app-release-unsigned.apk`: exit 0; all five packaged ARM64 libraries satisfy ELF LOAD and APK ZIP 16KB alignment.
- `python3 .tools/shared-toolchain-runtime-20261111.py`: `PASS`, API 36, page size 16384; shared SDK emulator booted in 97442 ms with the retained AVD. `VaultContractTest` returned `OK (3 tests)` for Google migration, committed cross-platform fixture and native RFC/backup/reopen. The harness stopped its own emulator; no userdata wipe.
- `bash android/scripts/gradle-local.sh --version`, after deleting local tool copies: Gradle 8.11.1 / JDK 17.0.20.1, exit 0.
- Shell syntax, Python AST parsing and `git diff --check`: pass.

Detailed ignored evidence is under `.tools/logs/`: `shared-rust-build-20261111.log`, `shared-android-build-20261111.log`, `shared-native-{debug,release}-20261111.log`, `shared-native-contract-api36-20261111.log`, `shared-runtime-20261111.json`, `shared-sdk-copy-validation-20261111.json`, `shared-sdk-packages-20261111.txt` and `shared-toolchain-migration-20261111.json`. The ignored runtime harness is retained for reproducing this run.

## Resulting paths and versions

- SDK: `/Users/jiun/Library/Android/sdk`; scripts honor `ANDROID_SDK_ROOT`, then `ANDROID_HOME`, then this default. Ignored `android/local.properties` was updated to match.
- Installed SDK packages: `platforms;android-36` rev 2, `build-tools;35.0.0`, `ndk;28.2.13676358`, `platform-tools` 37.0.1, `emulator` 37.2.12, `system-images;android-36;google_apis_ps16k;arm64-v8a` rev 7. The existing command-line tools directory was copied too.
- Gradle wrapper 8.11.1 remains checksum pinned; distribution and cache use `~/.gradle`. Cargo downloads use `~/.cargo`.
- Rustup toolchain `1.94.0` explicitly selects cargo, rustc and rustdoc; installed targets are `aarch64-apple-darwin` and `aarch64-linux-android`. The default stable compiler selection was not changed.
- Retained project state: `.tools/avd/otpeek-fixture-36-16k*`, `.tools/android-user` including debug signing key, private ADB port 5045, emulator ports 5660/5662, JDK17, downloads/bundletool, verification outputs, logs, final Windows artifacts and DPAPI evidence. Compilation outputs remain project-specific under `core/target/` and Android build directories.
- Swiq configuration, Corretto21 and other project source trees were not modified.

The SDK copy used APFS `cp -cRp`, then SHA256 validation of 20,363 files (9,337,578,408 bytes), preserving modes and symlinks. The first comparison failed solely on `.knownPackages`: sdkmanager regenerates that SDK-location cache. The successful comparison excludes only this cache, not package contents. Rustup installation automatically updated the rustup manager from 1.29.0 to 1.29.3; the selected compiler remains 1.94.0.

## Cleanup and actual disk accounting

Removed approved private cache/output copies: `.tools/gradle-home/caches/8.11.1`, `.tools/gradle-home/caches/modules-2`, `.tools/rust/share/doc`, `.tools/gradle-8.11.1`, `.tools/wrapper` and `.tools/msstore/evidence/selfcontained-qa/payload`. The latter is the old expanded reproducible payload; its MSIX and QA evidence were retained. After builds and runtime validation passed, removed the remaining `.tools/sdk`, `.tools/rust` and `.tools/gradle-home` copies.

Total allocated blocks attributed to removed paths: **13,257,908,224 bytes (12.35 GiB)**. This is not physical space reclaimed: APFS clone extents are shared and the required builds regenerated caches and outputs.

`df -k .` available blocks: initial **57,775,248 KiB**, final **54,419,180 KiB** (net **−3.20 GiB** over that observation interval). The exact statvfs snapshot immediately before deletion was **60,564,688,896 bytes**, versus **55,725,240,320 bytes** after cleanup/validation (net **−4,839,448,576 bytes / −4.51 GiB**). Both observations are recorded because intervening filesystem activity changes the baseline. No positive net space recovery is claimed.

Required validation regenerated approximately 1.45 GiB in `core/target`, 258 MiB in Android app build output, 1.44 GiB in shared Gradle cache and a 626 MiB pinned Rust toolchain, alongside other dependency downloads. These are retained rather than deleting shared caches or final outputs to improve the reported number. Filesystem deltas also include concurrent machine activity and cannot be attributed exclusively to this task.

## Evidence limits and choices

The checks establish shared-path build compatibility, native binding execution against public fixtures, retained AVD boot and 16KB packaging. They do not establish new release UI acceptance, Windows DPAPI recovery, Store authentication or Store submission. Those remain separate work; the Windows host was reported offline by the user. No real vault, secret or account authentication was used in these tests.

Implementation choices within the authorized migration: retain the existing JDK17 fallback, copy the complete existing SDK without changing package coverage, pin Rust to the existing 1.94.0 compiler, preserve project-private AVD/key/output paths, and reuse three existing native fixture tests rather than rerun the entire UI matrix. No unverified claim about Swiq build compatibility or physical clone-space reclamation is made.
