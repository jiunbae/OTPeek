# Disposable Android UI QA

**2026-10-27 cleanup:** only the API36/ARM64/16KB AVD `otpeek-fixture-36-16k` remains. The bundle runtime helper below still targets this AVD. The `fixture-ui.py` phases below are historical AOSP35 instructions: their guarded AVD has been removed, so these commands are currently unavailable. Their guard has not been widened to an unverified OS/AVD. Preserve their existing results; do not recreate extra images for routine QA. API36 Compose instrumentation can run on the retained fixture AVD with the isolated ADB helper.

Run from this worktree only. These helpers use the isolated ADB server/loopback ports in `../scripts/adb-fixture.sh`; they do not select attached physical devices. `fixture-ui.py` accepts only `otpeek-fixture-aosp35` with an installed debuggable app and no active vault. It creates public RFC fixture data, uninstalls that fixture app, and reinstalls an empty debug APK afterwards. Credential phases temporarily set/clear a public PIN on that disposable AVD. Do not use a personal device or an AVD containing user accounts.

Build the debug/test APKs first, install the debug APK with the fixture helper, and boot the local AOSP35 AVD. Keep the system/app language English and the normal font size for the shell UI driver. The Compose instrumentation tests separately cover Korean/200% text. Run UI automation on each AVD sequentially; simultaneous UIAutomator/instrumentation sessions on the same device interfere.

```sh
python3 android/qa/fixture-ui.py credential
python3 android/qa/fixture-ui.py credential-recovery  # includes reboot and key invalidation
python3 android/qa/fixture-ui.py saf                  # picker cancel, v2 export, reinstall/restore, process death
python3 android/qa/fixture-ui.py legacy               # fresh v1 picker restore + new password persistence
python3 android/qa/fixture-ui.py camera               # denial, regrant, scan, native HOTP
```

`legacy` and `camera` require generated public fixtures under ignored `.tools/verification/`. Generators use JDK crypto for **test data only** and the existing pinned ZXing dependency; production OTP/backup crypto remains in Rust.

```sh
mkdir -p .tools/verification
QA_JAVA="$PWD/.tools/jdk/jdk-17.0.20.1+1/Contents/Home/bin/java"
QA_ZXING_JAR=$(rg --files "${GRADLE_USER_HOME:-$HOME/.gradle}/caches/modules-2/files-2.1/com.google.zxing/core/3.5.3" | rg '/core-3.5.3.jar$')
"$QA_JAVA" android/qa/GenerateLegacyFixture.java .tools/verification/legacy-fixture.otpbackup
"$QA_JAVA" -Djava.awt.headless=true -cp "$QA_ZXING_JAR" \
  android/qa/GenerateQrFixture.java .tools/verification/qr-camera-fixture.png
```

For the camera phase, start the **stopped** AOSP35 AVD with the same local env as the Android README, console5660, and add `-camera-back "imagefile:$PWD/.tools/verification/qr-camera-fixture.png"`. Its Emulator37 imagefile camera has a rotated/cropped viewport; the generated inset was measured to keep the entire QR/finder patterns in the 640×480 analysis frame. This is a test fixture arrangement, not a change to production decoding.

Optional frame diagnostic, only on that public-image emulator:

```sh
bash android/scripts/gradle-local.sh -PcameraFixtureProbe=true :app:assembleDebugAndroidTest
bash android/scripts/adb-fixture.sh install -r android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
bash android/scripts/adb-fixture.sh shell am instrument -w -e fixture public-rfc \
  com.otpeek.app.debug.test/com.otpeek.app.CameraFixtureProbe
# Restore the ordinary AndroidJUnitRunner test APK before running the normal suite:
bash android/scripts/gradle-local.sh :app:assembleDebugAndroidTest
```

The probe is test-APK-only, requires an emulator and explicit fixture argument, and writes a frame to the fixture app cache for diagnosis. Never run it with a webcam or user image. It reports layout and a boolean, without printing decoded QR/secret/VMK. It is absent from the release artifact.

## AAB → R8 → 16KB runtime

The universal APK is signed with the **local debug fixture key**, never an production signing key. This does not publish or reserve anything in Play.

```sh
"$QA_JAVA" -jar .tools/downloads/bundletool.jar build-apks \
  --bundle=android/app/build/outputs/bundle/release/app-release.aab \
  --output=.tools/verification/release-universal.apks --mode=universal --overwrite \
  --ks=.tools/android-user/debug.keystore --ks-key-alias=androiddebugkey \
  --ks-pass=pass:android --key-pass=pass:android
python3 - <<'PY'
from pathlib import Path
from zipfile import ZipFile
with ZipFile('.tools/verification/release-universal.apks') as archive:
    Path('.tools/verification/release-universal.apk').write_bytes(archive.read('universal.apk'))
PY
python3 android/scripts/verify-native.py .tools/verification/release-universal.apk
python3 android/qa/bundle-runtime.py
```

The runtime helper starts/stops only its own `otpeek-fixture-36-16k` emulator at console5662. It refuses an existing release package, checks PAGE_SIZE=16384, then verifies native vault creation, manual HOTP, process death, password reopening and the persisted counter before uninstalling its fixture release app. Default debug fixture data is not used. The report distinguishes emulator evidence from physical biometric/camera/OEM/low-memory QA.
