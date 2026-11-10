# Android 구현 검증 — 2026-10-13

후속 결과: [2026-10-17 QA](QA_20261017.md). 아래는 최초 구현 당시 기록이며, API26–34/시스템 파일 복구/카메라/PIN/재부팅 검증은 후속 문서가 최신이다.

사용자 후속 승인 “바로진행하세요”로 추천안을 채택해 **로컬 MVP 구현과 아래 검증을 완료**했다. 독립 브랜치 `feat/android-bootstrap-20261013`만 최신 main `54ee0bf`로 fast-forward했다. 원본 worktree의 Windows 삭제 변경 및 다른 Apple/Windows 작업은 변경하지 않았다. 운영 signing/Play 예약·게시·push·PR·외부 연락은 수행하지 않았다.

Kotlin2.1.21/Compose BOM2025.05.01, AGP8.10.1/Gradle8.11.1/JDK17, NDK r28c, Rust1.94/UniFFI0.29.5, JNA5.17.0, CameraX1.4.2/ZXing3.5.3. target/compile36, min26, ARM64. 로컬 패키지 `com.otpeek.app` (debug `.debug`); Play에서 이름의 소유/사용 가능성은 미검증이다. 기존 Rust product `.rs`, public API, 알고리즘, vault 포맷, Cargo.lock은 변경하지 않았다.

## 구현 범위

수동 TOTP/HOTP 등록, offline QR/Google migration URI → Rust parser, 코드 표시·복사·계정 삭제, 비밀번호 암호화 vault, 선택 Android Keystore 인증형 VMK wrapping, background 잠금, sensitive clipboard, SAF v2 암호화 백업과 v2/v1 복구를 구현했다. 위젯/WebDAV·광고·서버·analytics는 후속 범위다. 앱 manifest에 INTERNET permission은 없다.

vault/wrapped VMK/staging/active pointer는 `noBackupFilesDir`에 저장한다. cloud/D2D 추출 제외 규칙과 allowBackup=false를 적용했다. 복구는 staging 검증 후 active pointer를 atomic 전환한다. 기존 vault 복구는 master/VMK를 유지하며, 빈 기기의 v2 복구는 backup password가 master password가 된다. HOTP는 명시 소비 동작만 counter를 증가시키고 저장 실패 시 client를 잠근다. 암호학 구현은 Rust에서 재사용하며 플랫폼 AES-GCM은 VMK wrapping에만 사용한다.

## 실행 결과

| 검사 | 최종 상태 | 실제 근거 / 제한 |
|---|---|---|
| 초기 core/vault/sync/FFI fixture | **64개 통과** | [최초 조사 기록](VALIDATION.md): 28+20+14+2, 운영 backend/keyring 미사용 |
| feature 분리 후 host FFI 회귀 | **2개 재실행 통과** | `.tools/logs/host-ffi-regression.log`, 단일 test thread, 198.38초 |
| ARM64 Rust release + host UniFFI 생성 | **통과** | `.tools/logs/rust-build.log`; Android library에서 bindgen CLI 의존성 제외, target std/NDK linker 사용 |
| debug APK / test APK / release R8 APK / AAB | **통과** | `.tools/logs/android-fixed-build.log`, 최종 4분3초; release artifact에는 운영 서명 없음 |
| JVM BackupGuard fixture | **4개 통과** | `android/app/build/test-results/testDebugUnitTest/TEST-com.otpeek.app.BackupGuardTest.xml`, 비용/크기/legacy/truncation 검사 |
| lintDebug + release vital lint | **통과: 오류 0개** | debug lint warning 12개: pin된 버전 업데이트 제안 및 ARM64-only 범위의 ChromeOS ABI; 최소 API 오류는 수정 후 재검사 |
| API35 AOSP ARM64 runtime 4KB | **7개 통과** | PAGE_SIZE=4096, `.tools/logs/instrumentation-aosp-4k.log`, 21.372초 |
| API36 ARM64 runtime 16KB | **7개 통과** | PAGE_SIZE=16384, `.tools/logs/instrumentation-16k.log`, 49.627초 |
| debug/release의 모든 native ELF + APK ZIP | **통과** | `.tools/logs/native-{debug,release}-final.log`; packaged `.so` 5개 모두 LOAD ≥16384, zipalign -P16 |
| AAB page alignment | **통과** | bundletool1.18.1 `.tools/logs/bundle-config-final.json`: PAGE_ALIGNMENT_16K |
| release/R8 UI → native vault create | **통과** | `.tools/logs/r8-smoke.log`; fixture key로 복사본만 서명, 16KB AVD에서 cold launch → vault create/native load, 이후 fixture 앱 제거 |
| 실기기 / API26–34 runtime / OEM D2D | **미검증** | 실제 사용자 기기·vault·secret·Keychain을 사용하지 않음 |

Device fixture 7개는 native RFC HOTP/TOTP, HOTP 재열기/backup VMK 독립성/wrong password, committed cross-platform v2 fixture, Google migration fixture, staging merge/replace/실패 보존, Keystore wrapping/키 분실 후 master 복구, 디스크 쓰기 실패/최대 counter, Compose 수동 HOTP/복사/background 잠금을 검사한다. 모두 공개 RFC 데이터 또는 disposable UUID fixture 디렉터리를 쓴다. UI fixture는 기존 active vault가 있으면 건너뛰도록 보호하며 테스트 이후 자신이 만든 데이터만 정리한다.

**Keystore unattended fixture는 인증 UI를 통과시키기 위해 fixture-only 비인증 키를 생성한다. 제품 키는 인증 필수다.** 이 검사는 VMK wrapping 및 키 분실 계약을 입증하며 strong biometric/device credential의 실제 상호작용이나 하드웨어 보안 수준을 입증하지 않는다.

## 발생한 실패와 해결

- 최초 조사 Android cargo check는 target std 부재로 실패했다. 이후 worktree-local Rust Android std/NDK 설치 및 native release 빌드로 해소했다.
- 초기 target 빌드가 호스트 bindgen CLI까지 cross-compile하여 불필요하게 무거웠다. 이 작업의 cargo/rustc만 중단했다. `otpeek-ffi` default feature로 기존 bindgen 동작을 유지하고 Android는 `--no-default-features`로 빌드한다. API/crypto 변경은 없다.
- 기본 UniFFI Kotlin 생성은 JVM Cleaner를 API33 미만에서 참조하여 lint NewApi 3개가 발생했다. `android/uniffi.toml`의 `android=true`로 생성하고 API34 미만 JNA fallback을 사용하여 lint 오류 0개 및 빌드/기기 검사를 완료했다.
- 첫 Google API35 AVD instrumentation은 test 결과 전에 process crash를 반환했다. 확보한 crash log에는 시스템 Bluetooth SIGABRT가 있었고 앱 실패 원인은 확정하지 않았다. AOSP API35 fixture AVD로 전환해 7개 통과했다. 이 초기 실패를 앱 전체 호환성의 성공으로 간주하지 않는다. API36 Google 16KB AVD에서도 7개 통과했다.
- 기본 emulator 자동 등록이 다른 workspace의 ADB와 충돌할 수 있어 이 fixture만 ADB port5045, console5660/5662 및 명시 loopback TCP5661/5663으로 분리했다. 다른 workspace의 ADB/emulator는 중단하지 않았다.

## 도구와 재현

도구·다운로드·cache·debug signing key·fixture AVD는 ignored `.tools/`, Rust build는 `core/target/`, Android build는 `android/app/build/`에 격리했다. JDK/Gradle/Rust std는 공식 배포 checksum을 검증했고 SDK는 공식 sdkmanager로 설치했다. SDK 설치 약관은 승인된 도구 설치 범위에서 처리했다. 글로벌 Rust/Java/Android 설치나 사용자 키 저장소는 수정하지 않았다.

```sh
# 승인된 worktree root에서만 실행
bash android/scripts/gradle-local.sh :app:assembleDebug :app:assembleDebugAndroidTest \
  :app:testDebugUnitTest :app:lintDebug :app:assembleRelease :app:bundleRelease
python3 android/scripts/verify-native.py android/app/build/outputs/apk/debug/app-debug.apk
python3 android/scripts/verify-native.py android/app/build/outputs/apk/release/app-release-unsigned.apk
.tools/jdk/jdk-17.0.20.1+1/Contents/Home/bin/java -jar .tools/downloads/bundletool.jar \
  dump config --bundle=android/app/build/outputs/bundle/release/app-release.aab

# 자신의 disposable fixture AVD가 부팅된 경우에만. 16KB는 emulator-5662.
export OTPEEK_EMULATOR_SERIAL=emulator-5660
bash android/scripts/adb-fixture.sh shell getconf PAGE_SIZE
bash android/scripts/adb-fixture.sh install -r android/app/build/outputs/apk/debug/app-debug.apk
bash android/scripts/adb-fixture.sh install -r android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
bash android/scripts/adb-fixture.sh shell am instrument -w \
  com.otpeek.app.debug.test/androidx.test.runner.AndroidJUnitRunner
```

검증에 사용한 worktree-local AVD는 `otpeek-fixture-aosp35`(console5660)와 `otpeek-fixture-36-16k`(console5662)다. 검증 후 이 작업의 emulator 두 개만 종료했고 AVD는 ignored `.tools/avd/`에 남겼다. 다른 workspace의 emulator는 변경하지 않았다. 다시 시작할 때 ANDROID_USER_HOME/ANDROID_EMULATOR_HOME을 `.tools/android-user`, ANDROID_AVD_HOME을 `.tools/avd`, ADB server를 5045로 지정해야 한다.

추가 정적 검사: shell syntax, 한국어/영어 resource name 일치, XML parse, git diff whitespace, 변경 경로/ignored build 확인. Android helper는 이 fixture serial 둘만 허용하며 사용자 기기 자동 선택을 하지 않는다. 테스트/로그에는 실제 사용자 비밀값이 없고 assertion은 VMK/전체 secret을 출력하지 않는다.

## 출시 전 남은 게이트

실기기 강한 biometric/device credential enrollment·취소·재부팅/키 무효화·hardware security level, OEM D2D, 실제 QR 카메라/권한 거부/여러 Google migration QR, SAF provider 부분 쓰기·취소/파일 복구 end-to-end, legacy v1 Android 복구 end-to-end, 저사양 Argon2 메모리/지연, API26–34 기동, 회전/process death, 접근성/레이아웃·한국어 QA를 확인해야 한다. 기존 v1 코어 fixture와 Android magic dispatch 통과가 실제 SAF v1 복구 UI 검사를 대체하지 않는다. Google multi-QR completeness는 코어 미지원 계약을 유지하며 사용자에게 각 QR import를 안내한다.

운영 signing, 최종 패키지 이름 소유 확인, privacy/data safety/store 자료, Play 계정별 closed test/production 접근은 별도 출시 단계다. Emulator/fixture 통과만으로 production 출시 준비 완료를 선언하지 않는다. [Target API36 공식 정책](https://support.google.com/googleplay/android-developer/answer/11926878), [ARM64 요건](https://developer.android.com/google/play/requirements/64-bit), [16KB 공식 검증 절차](https://developer.android.com/guide/practices/page-sizes), [Keystore](https://developer.android.com/privacy-and-security/keystore), [Auto Backup/D2D](https://developer.android.com/identity/data/autobackup), [widget refresh](https://developer.android.com/develop/ui/views/appwidgets/advanced).

작업 식별: tmux `otpeek / ANDROID-BOOTSTRAP` pane `%45`, muxa alias `android`. 결과는 이 문서와 최종 tmux 답변에서 확인할 수 있다.
