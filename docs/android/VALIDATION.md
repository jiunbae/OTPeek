# Android 준비 검증 기록 — 2026-10-13

대상: `feat/android-bootstrap-20261013` / `1537193`, macOS ARM64 호스트.
이 기록은 호스트 코어 계약 검사와 Android 빌드를 구분한다. 모든 데이터는 기존 공개 fixture 또는 새 RFC fixture이며 사용자 데이터/키 저장소를 사용하지 않았다.

## 도구 인벤토리 (read-only)

| 항목 | 확인 결과 |
|---|---|
| Rust | rustc/cargo 1.94.0 (2026-03-02/2026-01-15) |
| 설치 target | aarch64-apple-darwin, aarch64-apple-ios, aarch64-apple-ios-sim, aarch64-unknown-linux-musl, x86_64-apple-darwin, x86_64-unknown-linux-musl |
| Android Rust target | `rustc --print target-list`에는 ARM64/x86_64 Android 등이 있지만 **설치되어 있지 않음** |
| Java/JDK | `/usr/bin/java`, javac는 macOS launcher. `java -version`, `/usr/libexec/java_home -V`는 Java Runtime 없음 반환. `/Library/Java/JavaVirtualMachines`에는 JDK 없음 |
| Gradle | PATH에서 실행 파일 없음, repo wrapper 없음. `~/.gradle` 캐시는 존재하지만 설치된 Gradle/JDK 근거가 아님. `~/.gradle/android/FakeDependency.jar`는 SDK가 아님 |
| Android SDK/NDK | ANDROID_HOME/ANDROID_SDK_ROOT/JAVA_HOME 미설정. `~/Library/Android/sdk`, `~/Android/Sdk`, `/opt/android-sdk`, `/usr/local/lib/android/sdk`, Homebrew 표준 Android/JDK 경로에서 설치 확인 안 됨 |
| Studio/에뮬레이터 | 표준 `/Applications`/사용자 Applications의 Android Studio, `~/.android/avd` 확인 안 됨. adb/emulator/sdkmanager/avdmanager PATH에 없음 |
| 실기기 | adb 부재로 연결 상태/기기 인증/페이지 크기는 미검증. adb server 시작/기기 접근하지 않음 |
| tmux/muxa | 현재 pane `%45`, alias `android`, 역할 android-preparation. 사용자 결정 대기 식별을 최종 갱신 |

인벤토리는 PATH와 명시된 표준 경로 확인이다. 모든 디스크를 검색해 다른 위치의 설치가 절대 없음을 증명한 것은 아니다. 설치/업그레이드/SDK license 동의는 수행하지 않았다.

## 실행 결과

| 검사 | 상태 | 근거/한계 |
|---|---|---|
| otpeek-core RFC/Base32/URI/migration integration fixture | **통과: 28개** | base32 7, migration 4, RFC 6, URI 11 |
| otpeek-vault integration fixture | **통과: 20개** | committed v2 password/key path, v1 conversion/wrong password, tamper, truncated/version/header, nonce/generation, password change, tombstone, atomic fixture file I/O; 227.90초 |
| otpeek-sync in-memory backend fixture | **통과: 14개** | WebDAV feature off; HTTP/운영 서버 없이 LWW/tombstone/counter/ETag retry/wrong-key; 56.84초 |
| otpeek-ffi Android contract fixture | **통과: 2개** | 직접 facade 호출; HOTP 소비·재열기·batch exclusion, backup 새 VMK, wrong password 비파괴, merge skip 및 replace counter 회귀 계약; 58.08초 |
| host FFI lib + bindgen build | **통과** | `libotpeek_ffi.dylib`, UniFFI 0.29.5. Android `.so`가 아님 |
| Kotlin 생성 | **통과** | `uniffi.otpeek`, native library `otpeek_ffi`, counter ULong, vault key ByteArray, SyncBackend callback, OtpClient close/destroy 확인. ktlint 미설치 warning; 생성 exit 0 |
| Kotlin 컴파일/JNA device load | **미검증** | JDK/SDK/Gradle 및 Android artifact 없음 |
| ARM64 Android cargo check | **실패: 환경 부재** | exit 101 / E0463 `can't find crate for core`, aarch64-linux-android std 미설치. NDK linker 단계에 도달하지 않음 |
| Android Keystore/QR/backup/widget/16KB/Play | **미검증** | 실제 Android shell, SDK/device 및 store 작업 없음 |

초기 offline core test는 `data-encoding v2.11.0` 캐시 부재로 실패했다. 실제 테스트 실패가 아니다. 이어 Cargo registry/cache/download를 이 worktree의 ignored 경로에 격리하여 `--locked`로 재실행했다. bindgen 최초 호출은 repo root에서 Cargo.toml을 찾지 못해 실패했으며 **core/ cwd로 수정하여 성공**했다. lockfile/manifest를 수정하지 않았다.

## 실행 선택 이유와 재현

workspace 전체/CLI(keyring)/Apple/Windows 테스트 대신 Android가 재사용할 코어의 4개 integration test target, vault의 기존 fixture 전용 integration target, sync의 in-memory backend target 및 작은 FFI contract target을 선택했다. vault는 Argon2 64MiB 동시 작업 증가를 피하려고 `--test-threads=1`로 실행했다. crypto 비용/파라미터를 낮추지 않았다. 동시 Cargo build는 artifact directory lock을 공유했다.

아래는 **이 worktree root에서만** 실행하는 명령이다. CARGO_HOME/CARGO_TARGET_DIR/TMPDIR는 검사 프로세스에만 지정한다. 실제 vault 경로/Keychain/비밀 env를 사용하지 않는다.

```sh
mkdir -p core/target/android-investigation/tmp
export CARGO_HOME="$PWD/core/target/android-investigation/cargo-home"
export CARGO_TARGET_DIR="$PWD/core/target/android-investigation/build"
export TMPDIR="$PWD/core/target/android-investigation/tmp"

cargo test --manifest-path core/Cargo.toml --locked -p otpeek-core \
  --test rfc_vectors --test base32_tests --test uri_tests --test migration_tests
cargo test --manifest-path core/Cargo.toml --locked -p otpeek-vault \
  --test vault -- --test-threads=1
cargo build --manifest-path core/Cargo.toml --locked -p otpeek-ffi \
  --lib --bin uniffi-bindgen
cargo test --manifest-path core/Cargo.toml --locked -p otpeek-sync \
  --test sync --no-default-features -- --test-threads=1
cargo test --manifest-path core/Cargo.toml --locked -p otpeek-ffi \
  --test android_contract_fixtures -- --test-threads=1

# metadata 확인을 위해 core/를 cwd로 사용한다.
(cd core && target/android-investigation/build/debug/uniffi-bindgen generate \
  --library target/android-investigation/build/debug/libotpeek_ffi.dylib \
  --language kotlin --out-dir target/android-investigation/kotlin)

# 현재는 target std 미설치로 실패하는 환경 검사 (다시 테스트할 때 별도 target-dir).
CARGO_TARGET_DIR="$PWD/core/target/android-investigation/android-check" \
  cargo check --manifest-path core/Cargo.toml --locked --offline \
  -p otpeek-core --target aarch64-linux-android
```

최종 결과 log는 ignored `core/target/android-investigation/{core-tests,vault-tests,sync-tests,ffi-tests,ffi-build,kotlin-bindgen,android-check}.log`에 있다. 생성 Kotlin은 `core/target/android-investigation/kotlin/uniffi/otpeek/otpeek.kt`. 이러한 build/cache artifact는 전달용 소스에 포함하지 않는다.

추가 fixture 소스: `core/crates/otpeek-ffi/tests/android_contract_fixtures.rs`. 제품 코드나 public API를 변경하지 않는다. assertion에 VMK bytes나 전체 계정/secret을 출력하지 않도록 boolean/카운터/공개 RFC 코드 검사만 사용한다.

## 다음 검증 게이트

사용자 합의 후 NDK ARM64 build, Kotlin release/R8 load, JNA 포함 ELF/zip 16KB, 4KB/16KB runtime, Keystore auth/invalidation/reinstall, SAF provider failure, KDF resource bound/invalid payload, HOTP persistence failure/overflow, multi-QR completeness 정책을 검증한다. 이 목록은 이번 조사에서 통과했다고 표시하지 않는다.
