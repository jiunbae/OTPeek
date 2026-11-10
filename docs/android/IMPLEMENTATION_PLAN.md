# OTPeek Android 구현 계획

**2026-10-25 후속:** 클립보드 선택 대기는 사용자 위임으로 해소됐다. 현재 동작과 회귀 결과는 [CLIPBOARD_QA_20261025.md](CLIPBOARD_QA_20261025.md)가 기준이며, 아래는 당시 조사/검증 이력이다.

작성일: 2026-10-13 (Asia/Seoul). 상태: **사용자 “바로진행하세요” 승인 후 로컬 MVP 구현·fixture 검증 완료. 실기기/출시 QA 대기**.

승인 후 추천안을 채택했다: 최신 main `54ee0bf`로 이 독립 브랜치만 fast-forward, Kotlin/Compose + Rust/UniFFI/JNA, minSdk26/ARM64, `com.otpeek.app`, 필수 master password/선택 기기 인증, OS backup 제외, 위젯·WebDAV 후속, Google migration QR별 import 제한. 아래 조사 내용은 최초 기준 `1537193`의 기록이다. 실제 빌드 결과는 [BUILD_VALIDATION.md](BUILD_VALIDATION.md)에 별도 기록한다.
작업 식별: tmux `otpeek / ANDROID-BOOTSTRAP`, pane `%45`, muxa alias `android`.

## 1. 최초 조사 범위와 확인된 가정 (아래는 구현 전 기록)

- 승인된 worktree `/Users/jiun/workspace/otpeek-android`, 브랜치 `feat/android-bootstrap-20261013`, HEAD `1537193`에서 조사했다. 첫 상태는 clean이었다.
- 원본 worktree의 Windows 삭제 변경은 사용자 제공 정보다. 원본 파일/상태를 읽거나 복구하지 않았다. Apple/Windows는 이 worktree 및 원격 Git blob을 읽기만 했다.
- 사용자 제공 전역 AGENTS.md 원칙을 적용했다. 상위 경로 `/`, `/Users`, `/Users/jiun`, `/Users/jiun/workspace`의 AGENTS.md와 worktree의 hidden 포함 파일 검색에서 추가 AGENTS.md는 발견되지 않았다. 원격 main에도 없다.
- `docs/ARCHITECTURE.md`의 frozen public API 및 v2 저장 계약을 준수한다. `docs/SPEC.md`, `DATA_FORMAT.md`, `BACKUP_FORMAT.md`, `SYNC.md`, `TESTING.md`를 기존 계약 근거로 사용한다. `context/PROJECT_SPEC.md`의 옛 Windows OTP.NET/클라우드 설계보다 실제 Rust 구현과 Architecture v2를 우선한다.
- Play 계정 복구/인증/제한 해제는 사용자 확인 정보다. 로그인과 계정별 production 접근 상태는 조사하지 않았다.
- 아래 기술 스택, 최소 OS, 패키지명, 보관/잠금 정책, 일정은 **제안**이다. SDK 설치, Android 앱 코드, 새 운영 서비스, 공개 API 변경, 포맷 변경, rebase, push/PR/게시를 실행하지 않았다.
- 미확정: Android ELF/JNA 로딩, 16KB 실제 실행, 저사양 Argon2 비용, 기기별 Keystore/복구 동작, QR 다중 배치 지원 범위. 호스트 테스트가 이 항목의 성공을 입증하지 않는다.

## 2. 로컬/원격 파일 근거

`git ls-remote origin refs/heads/main`이 `54ee0bf1a235b728cb469a2fda9ee444f01c57d7`을 반환했고 로컬 `origin/main`과 일치했다. fetch 없이 확인했다. 로컬은 원격 main보다 46개 커밋 뒤이며 Android 관련 파일은 두 tree 모두 없다. `android/`, Gradle wrapper/build/settings, AndroidManifest, Kotlin shell도 없다.

전체 파일별 변경 목록은 [REMOTE_DIFF.tsv](REMOTE_DIFF.tsv)에 보관했다 (`git diff --name-status HEAD origin/main`). A/M/D는 **원격이 로컬과 다른 방향**이며 작업 중 삭제한 파일 목록이 아니다.

| 근거 파일 | 실제 구현 / 원격 차이 | Android 영향 |
|---|---|---|
| `core/Cargo.toml`, `core/Cargo.lock` | 원격은 workspace 2.0.0 → 2.0.1 및 5개 crate 버전만 변경 | 의존성 버전/코어 계약은 동일 |
| `core/crates/otpeek-core/src/{algorithm,base32,uri,migration,types,lib}.rs` | 원격과 동일, SHA1/256/512 TOTP/HOTP, URI, migration parser | Kotlin으로 알고리즘을 재구현할 필요 없음 |
| `core/crates/otpeek-vault/src/lib.rs`, `tests/vault.rs`, `tests/fixtures/vault-v2.otpvault` | 원격과 동일, AES-256-GCM v2, Argon2id, v1 import | 포맷 유지 및 fixture 공유 가능 |
| `core/crates/otpeek-sync/src/lib.rs`, `tests/sync.rs` | 원격과 동일, merge/WebDAV | Android sync UI/백엔드 연결은 아직 없음 |
| `core/crates/otpeek-ffi/{Cargo.toml,src/lib.rs,src/bin/uniffi-bindgen.rs}` | 원격과 동일, UniFFI proc macro 0.29.x, namespace `otpeek` | Kotlin generator를 기존 host library에 적용 가능 |
| `apple/scripts/build-core.sh` | Swift 생성 + XCFramework 조립, 동일 | Android에 직접 실행하지 않고 동일 FFI metadata 사용 |
| `apple/Shared/KeychainHelper.swift`, `VaultAccess.swift` | VMK만 Keychain, AfterFirstUnlockThisDeviceOnly, App Group vault, widget openWithKey; 동일 | Android Keystore는 export 불가이므로 별도 VMK wrapping 필요 |
| `apple/Shared/OtpStore.swift`, `AppLock.swift` | 원격에 백업 magic 분기, 파일 접근 및 biometric/UI 잠금 개선 | 오래된 shell을 그대로 베끼지 않는다. UI 잠금과 key-use 인증을 구분 |
| `apple/Shared/OtpGenerator.swift`, `OtpModelBridge.swift`, `CloudKitSyncBackend.swift` | Rust OTP 호출, 시간 UI helper, opaque blob CloudKit | OTP/merge는 공유 코어, native UI/전송만 shell 책임 |
| `windows/Otpeek.Core.Windows/Services/{SecureStorageService,OtpClientService,QrCodeService,WebDavSyncBackend}.cs` | 동일, DPAPI CurrentUser VMK wrapping, FFI facade, QR 텍스트 추출, WebDAV callback | 플랫폼 키 저장과 raw QR → Rust 분리의 참고 |
| `windows/Otpeek.Core.Windows/Services/QuickOtpCodeProvider.cs`, `windows/Otpeek.Widget/*` | 원격에서 widget/코드 공급 및 진단 변경 | Android widget 동작 보장의 근거는 아님 |
| `docs/ARCHITECTURE.md`, `SPEC.md`, `DATA_FORMAT.md`, `BACKUP_FORMAT.md`, `SYNC.md` | 동일 | frozen 계약 유지 |
| `docs/RELEASE.md`, `TESTING.md`, Apple UI/출시 파일, Windows UI/출시 파일 | 원격 변경 | 전체 파일 목록은 TSV; Android 시작 전 기준 커밋 결정 필요 |

권장: 다음 구현 단계에서 최신 main을 기준으로 삼되, **이 조사에서는 브랜치를 움직이지 않는다**. 사용자 합의 후 독립 worktree에서 기준을 맞추고 fixture를 다시 확인한다. 옛 로컬 Apple 광고 코드가 원격에서 제거된 사실을 Android 광고 도입 근거로 삼지 않는다.

## 3. 공유 코어 계약과 재사용 한계

### OTP와 QR

- `algorithm.rs`: RFC HOTP/TOTP, 마지막 HMAC 바이트의 dynamic truncation, 밀리초 기반 `generate_code`. `code()`는 HOTP를 증가시키지 않는다. `codes_at()`은 TOTP만 반환하고 실패 계정을 생략한다.
- `OtpClient::next_hotp` (`ffi/src/lib.rs:695`): 현재 counter의 코드 계산 → saturating increment → updated_at → persist → 이전 counter 코드 반환. UI의 “생성/사용” 한 번에만 호출하고, 일반 화면 갱신/복사는 호출하지 않는다. 반복 클릭을 직렬화한다. 생성 결과를 잠시 유지하고 새로 읽은 다음 counter 코드와 혼동하지 않는다.
- `uri.rs`: 기본 SHA1/6자리/30초, issuer query 우선, HOTP counter 기본 0. parser/add_account는 digits/period 전체 유효성을 저장 전에 보장하지 않는다. 알고리즘은 digits 1..9를 허용하지만 모델 문서는 6..8이다. Android 입력 정책은 6..8, period >0, counter ULong 범위로 제안하고 실제 생성 호출로 검증한다. 미지원 입력을 조용히 바꾸지 않는다.
- `migration.rs`: 표준/url-safe base64와 padding, protobuf RAW secret → Base32, HOTP 지원. **version/batch_size/batch_index/batch_id 무시**, unknown algorithm/type/digits를 default로 매핑한다. 여러 QR의 완전성·중복·지원하지 않는 값의 경고를 현재 FFI만으로 보장할 수 없다.
- FFI `add_from_uri`는 두 URI를 지원하지만 저장까지 바로 수행하며 매 scan마다 새 UUID를 준다. `parse_otpauth_uri`는 별도 FFI에 있으나 migration preview 전용 FFI는 없다. 첫판은 URI당 import 후 계정 수 확인, 같은 scan 이벤트 중복 억제, 여러 QR는 각각 처리하고 전체 migration 완료를 주장하지 않는 제한을 제안한다. 원자적인 preview/선택/배치 완전성 기능이 필요하면 frozen API를 보존하는 추가 adapter에 별도 합의가 필요하다.
- 카메라/QR decoder는 텍스트만 반환한다. secret, URI, generated account `toString()`를 로그/analytics/오류 보고에 넣지 않는다. 카메라 거부 시 수동 등록 경로가 있어야 한다.

### Vault, 키 및 저장 실패

- `vault/src/lib.rs`: random 32-byte VMK, AES-256-GCM, fresh 12-byte nonce, 전체 prefix/header를 payload AAD로 인증. Argon2id 기본 64MiB / t=3 / p=1, password-derived KEK가 VMK를 감싼다. `change_password`는 VMK 유지. v1은 PBKDF2-SHA256 100k AES-GCM import만 지원.
- `vault_key()`/`open_with_key()`는 **raw VMK bytes**를 주고받는다. non-exportable Android Keystore key를 직접 raw VMK 대신 전달할 수 없다. 제안: AndroidKeyStore가 만든 AES wrapping key로 VMK를 GCM 암호화하고 private storage에 nonce+ciphertext+tag를 저장. Rust vault 암호화는 그대로 유지한다.
- raw VMK는 unlock 시 JVM/Rust 메모리에 존재한다. Rust Vault Drop은 VMK를 zeroize하지만 payload secret, FFI String/byte 복사와 Kotlin immutable String의 완전한 zeroization은 보장하지 않는다. ViewModel에는 issuer/name/code만 투영하고 secret 모델을 최소 수명으로 다룬다. `SavedStateHandle`, Bundle, 평문 DB/preferences에는 넣지 않는다.
- Mutex는 client 단위다. 저장은 destination inode advisory lock + 같은 디렉터리 temp/fsync/rename이다. rename 후 다른 프로세스의 잠금 일관성, parent dir fsync 및 read-modify-write lost update까지 보장하지 않는다. 첫판은 **단일 프로세스/단일 client와 직렬 작업**을 권장한다.
- 변경 메서드는 메모리 payload를 먼저 바꾸고 persist하며 실패 시 롤백하지 않는다. 디스크 오류 시 client를 폐기하고 저장된 vault를 다시 열어 상태를 재확인한 후 작업을 재개해야 한다. 실패한 HOTP 결과는 반환/복사하지 않는다. 새 vault의 실패로 빈 파일이 남는 경우도 fixture로 검증할 게이트다.
- HOTP counter 최대값에서 saturating_add는 재사용을 막지 못한다. Android에서는 ULong.MAX_VALUE의 생성 중단을 제안한다. 오래된 account를 update_account로 덮으면 카운터가 낮아질 수 있으므로 첫판에서 counter 편집을 제공하지 않는다.
- password open은 인증 전 header의 Argon2 파라미터를 사용한다. 파일 크기 제한만으로 malicious KDF 비용을 막을 수 없다. 외부 백업 입력의 크기/헤더/KDF resource bound와 취소/오류 처리 fixture는 출시 차단 게이트다. Android에서 crypto를 재구현하지 않고 제한된 preflight 또는 기존 public signature를 유지한 코어 내부 보호를 별도 검토한다. payload version 검증/모델 검증 부족도 외부 파일 fixture 대상으로 남긴다.

### 백업/복구와 sync는 서로 다르다

- `export_backup(password)`는 **새 VMK**의 v2 container를 만든다. vault master password와 backup password는 별개다. `restore(blob,password)`는 blob의 VMK/password wrapping을 그대로 보존하며 대상 경로를 저장한다. 이를 새 기기에 복구하면 backup password가 그 vault의 master password가 된다. UI에서 명확히 알리고 필요 시 코어 change_password를 호출한다.
- `import_backup(...,merge=false)`는 payload 전체 교체, 기존 로컬 VMK 유지. HOTP counter가 오래된 백업 값으로 회귀할 수 있다. merge=true는 모르는 id 추가/삭제된 id 부활만 하고 **살아 있는 같은 id는 counter가 더 커도 skip**한다. SyncEngine merge와 동일하지 않다. v1은 새 UUID를 주므로 재import 중복 가능.
- 권장 복구: 빈 기기는 staging 경로에 restore → 계정/코드 검증 → 새 Keystore wrapping 저장 및 활성화. 이미 vault가 있으면 기본 추가 병합, 교체는 계정 수와 HOTP 회귀 경고 후 명시 선택. 실패 시 기존 vault/key 쌍 유지. SAF 선택 URI는 Rust 파일 경로가 아니므로 shell에서 제한된 bytes로 읽고 private staging 파일을 사용한다.
- 빈 기기의 v1 파일은 v2 restore에 넣을 수 없다. 새 master password로 staging vault create → import_backup_v1 → 검증 → 활성화 흐름을 사용한다. 기존 v1 backup password와 새 vault master password를 구분한다.
- `sync/src/lib.rs`: id별 LWW(updated_at), 동률은 tombstone 우선, 완전 동률은 serialized content 비교로 결정. counter는 두 값의 max, tombstone은 저장 시 90일 이후 purge. ETag conditional store/create-only, 최대 3 attempts. **동시에 두 기기가 같은 HOTP counter를 사용하지 않도록 해 주지는 않는다**.
- sync는 동일 VMK가 필요하다. 같은 비밀번호로 독립 create하거나 export backup을 import한 기기는 동일 sync key가 아니다. remote blob을 password restore해 bootstrap해야 한다. 비밀번호 변경은 remote/local wrapped header 전파 시나리오까지 별도 fixture 필요.
- FFI sync는 성공 후에만 local persist; conflict/network/persist 실패 중 메모리와 원격/디스크가 달라질 수 있다. WorkManager 재시도만으로 해결했다고 볼 수 없다. Android sync 운영은 첫판에서 제외하는 편을 권장한다.

## 4. 추천 첫판과 Android 설계 (후속 승인으로 채택)

첫판: **수동/QR 등록 → TOTP/HOTP 표시·복사 → 암호화 저장 → 비밀번호 백업·복구**. 계정 삭제/잠금 및 복구 오류 안내는 이 흐름을 안전하게 만들기 위한 최소 UI다. 광고, 결제, 계정 서버, favicon 네트워크 조회는 첫판에 제안하지 않는다.

| 영역 | 추천 / 선택 필요 |
|---|---|
| UI | Kotlin + Jetpack Compose/Material 3, 한 app module과 작은 Rust 호출 adapter. ViewModel + coroutine로 blocking Argon2/I/O/FFI를 main thread 밖에서 직렬화 |
| shared core | 기존 `otpeek-ffi` cdylib + 동일 lockfile UniFFI bindgen. host library metadata로 Kotlin 생성, NDK로 ABI별 `libotpeek_ffi.so` 빌드, `jniLibs/<abi>`에 배치 |
| FFI runtime | UniFFI 0.29 Kotlin은 JNA AAR 필요. JNA 정확 버전과 native packaging/R8 keep rule을 로딩 gate 후 pin. 직접 JNI 재작성이나 UniFFI 업그레이드는 별도 합의 |
| SDK | compile/target API 36 제안, minSdk 26 제안 (API 23까지 확대 시 key auth/OS/검증 매트릭스 증가). AGP API36 지원 버전, 호환 Gradle wrapper/JDK 조합 pin |
| build 도구 후보 | 검증 기준 예: AGP 8.10 계열 / Gradle 8.11.1 / JDK17 / NDK r28 이상. 현시점 최신 버전을 자동 채택하지 않고 Kotlin/Compose 및 Rust 호환 검증 후 확정 |
| ABI | 첫 출시 ARM64(`aarch64-linux-android` → `arm64-v8a`). 테스트용 x86_64는 필요 시 추가. ARM32는 선택 사항이며 해당 64-bit 대응 라이브러리 없이는 배포하지 않음 |
| QR | CameraX + offline ZXing 계열 decoder 후보. Play Services/ML Kit는 다운로드/데이터 정책 차이가 있어 사용자 합의 없이 채택하지 않음 |
| vault 위치 | `context.noBackupFilesDir` 하위 `vault.otpvault` 및 wrapped VMK; 임시 파일도 동일 private/no-backup 범위. SharedPreferences/DataStore에는 비밀 없는 설정만 |
| 백업 | Storage Access Framework create/open document. v2 export, v2/v1 import magic dispatch. provider 쓰기 성공을 확인하고 부분 쓰기/취소 처리. 평문 export 없음 |
| 패키지 후보 | `com.otpeek.app` 또는 `dev.jiun.otpeek`. 소유/브랜딩·기존 사용 여부는 미검증. **제안만 했고 예약/생성/게시하지 않음** |

Rust Android target은 std 지원 Tier 2지만 NDK linker와 target std 설치가 필요하다. FFI는 sync의 default WebDAV/ureq/rustls/ring을 함께 가져오며 ring C/assembly에는 Android NDK CC/AR 설정이 필요하다. CLI의 keyring/clipboard는 FFI 의존 경로에 포함되지 않는다. FFI의 UniFFI `cli` feature가 target library build에도 켜져 있어 bindgen 의존성 규모가 크다. 문제가 확인되기 전에는 feature 분리 리팩터링을 하지 않는다. `cargo-ndk`는 필수로 추가하지 않고 NDK clang/linker 설정으로 우선 검사한다. [Rust Android target 문서](https://doc.rust-lang.org/rustc/platform-support/android.html), [UniFFI 0.29 Kotlin/Gradle 문서](https://mozilla.github.io/uniffi-rs/0.29/kotlin/gradle.html).

### 보안/데이터 보관 선택

추천은 필수 master password + 선택 biometric/device credential unlock, background 전환 즉시 화면 마스킹/client 폐기 및 재인증이다. 기기 인증 실패/키 무효화/재설치/분실에는 master password 또는 별도 백업 password로만 복구한다. OS 인증이 없는 기기는 password-only로 동작시키는 방향을 제안한다. wrapping key의 authentication policy는 biometric과 device credential, 유효 시간, enrollment invalidation을 명시해 fixture 기기로 검증해야 한다. StrongBox는 필수로 하지 않고 가능한 하드웨어 보안 수준을 확인한다.

자동 OS backup/D2D에는 vault/wrapped key/계정 메타데이터를 제외하고 **사용자 명시 암호화 파일 백업만** 허용하는 안을 권장한다. Keystore wrapping key의 기기 이전을 기대하지 않는다. 다른 기기로 복원할 때 새 wrapping key를 만들고 password 복구를 안내한다. 백업 password 분실은 복구 불가이며 앱 삭제 전 백업 안내가 필요하다. `allowBackup=false`만으로 모든 제조사의 D2D를 막는다고 가정하지 않는다. no-backup storage + Android 12+ dataExtractionRules의 cloud/device transfer 제외 + Android 11 이하 fullBackupContent 규칙을 검증한다. [Keystore](https://developer.android.com/privacy-and-security/keystore), [Auto Backup](https://developer.android.com/identity/data/autobackup).

OTP 복사는 sensitive clip flag를 설정하고 앱 소유 clip에 한해 expiry/잠금 시 정리한다. 다른 앱이 바꾼 clipboard를 지우지 않으며 clipboard의 완전한 접근 차단을 보장하지 않는다. secret 화면/QR/계정 목록은 screenshot·recent task 노출 차단을 제안한다. 로그/크래시/backup preview/위젯 payload에 secret을 넣지 않는다. [공식 clipboard 지침](https://developer.android.com/develop/ui/views/touch-and-input/copy-paste).

### 위젯·WebDAV 우선순위 옵션

| 선택 | 추가 작업량 추정 | 결정/검증 |
|---|---|---|
| 둘 다 후속 (권장) | 첫판 일정에 추가 없음 | 첫판 보안·복구 계약을 먼저 안정화 |
| 홈 위젯 먼저 | 3–5 개발일 + 배터리/런처 QA | 기본은 계정명/앱 열기, OTP는 opt-in. 잠금 중 코드 숨김, stale code 만료, refresh 표시, secret/URI를 RemoteViews/Intent에 전달 금지. HOTP 소비 버튼 제외 |
| WebDAV 먼저 | 4–7 개발일 + 실패/동시성 QA | 코어 merge 유지, TLS 검증, credential Keystore wrapping, ETag/3-attempt, 동일 VMK bootstrap, offline/clock skew/failed persist/HOTP 동시 소비 fixture |

Android widget의 `updatePeriodMillis` 최소는 30분이므로 30초 TOTP 자동 정확 갱신을 기대할 수 없다. 상시 background timer나 WorkManager로 만료 없는 코드를 약속하지 않는다. widget은 런처 host에 표시되는 정보라 OTP opt-in은 잠금 정책·인증형 key 접근과 충돌할 수 있다. 첫 후속안은 tap → unlock 앱 흐름이며, 자동 코드 표시를 선택하려면 별도의 exposure/expiry 설계를 합의한다. 공식 문서는 refresh 제한을 설명하지만 OTP 위젯의 개별 보안 승인을 제공하지 않는다. [Widget refresh 문서](https://developer.android.com/develop/ui/views/appwidgets/advanced).

## 5. Play/ARM64/16KB 출시 게이트

2026-10-13 공식 문서 확인 기준 신규 일반 Android 앱/업데이트는 API **36 이상**을 target해야 한다. native Rust/JNA를 포함하므로 64-bit 및 16KB를 실제 artifact 기준으로 검증한다. 계정 복구가 앱별 production 테스트 요구까지 없애는 것은 아니다. 신규 개인 계정에 해당하는 경우 closed testing 12명/연속 14일 및 production 접근 신청 요건을 계정 화면에서 사용자가 확인해야 한다. [Target API 정책](https://support.google.com/googleplay/android-developer/answer/11926878), [64-bit 요건](https://developer.android.com/google/play/requirements/64-bit), [개인 계정 테스트 요건](https://support.google.com/googleplay/android-developer/answer/14151465).

16KB gate: AGP ≥8.5.1 packaging, NDK r28 이상 후보, Rust linker alignment 확인, **모든** bundled `.so`(JNA `libjnidispatch.so` 포함)의 ELF LOAD alignment ≥2**14, APK zip alignment 확인 및 AAB `PAGE_ALIGNMENT_16K`. `llvm-readelf -lW`, `zipalign -c -P 16 -v 4`, `bundletool dump config`로 검사한다. ARM64 4KB/16KB emulator 또는 실기기에서 `adb shell getconf PAGE_SIZE`가 각각 4096/16384인지 확인하고 vault/FFI/restore를 실행한다. NDK 버전만으로 Rust/JNA 호환을 선언하지 않는다. 확인한 공식 가이드는 API35+ 앱의 64-bit 16KB 지원 요건과 2027-02-01 미지원 업데이트 차단일을 기재한다. 이 앱은 신규 출시부터 지원을 검증하는 안이다. [16KB 공식 가이드](https://developer.android.com/guide/practices/page-sizes).

UniFFI 문서의 최소 JNA 5.12.0을 그대로 pin하면 부족할 수 있다. JNA 자체 changelog에 5.16.0 및 5.17.0의 Android 16KB fixes가 있으므로 최소 5.17 이후 후보를 검토하고 정확 AAR native library를 검사한다. [JNA upstream 변경 기록](https://github.com/java-native-access/jna/blob/master/CHANGES.md). API36 지원 조합의 기준은 [AGP 8.10 공식 compatibility](https://developer.android.com/build/releases/agp-8-10-0-release-notes)로 확인했다.

## 6. 구현 순서와 작업량

한 개발자 기준 예상이며 Play 대기/closed testing 기간과 기기 조달은 별도다. 총 **12–20 개발일** (아래 독립 단계 합산). 새 코어 보호 변경이 필요하면 별도 산정한다.

| 단계 | 추정 | 완료 검사 |
|---|---|---|
| 기준 커밋/스택 합의, 도구/ABI/FFI smoke | 2–3일 | ARM64 .so 및 Kotlin load 성공, generated checksum 일치, 16KB native gate |
| vault/Keystore/잠금/password 복구 | 3–5일 | fixture vault reopen, 인증 취소, reboot, 키 무효화, 파일/키 commit 실패에서 기존 상태 보존 |
| 수동·QR 등록, TOTP/HOTP 표시/복사 | 3–5일 | RFC device vectors, UTC/period 경계, ULong counter, 중복 scan, camera 거부, background lock |
| SAF 백업/복구 및 v1 이관 | 2–4일 | cross-platform v2 fixture, wrong password/tamper/truncated/KDF bound, merge/replace 차이, 기존 데이터 보존 |
| release variant·접근성·보안/출시 자료 검증 | 2–3일 | R8 native load, ARM64+16KB AAB/APK, OS backup 제외, uninstall/reinstall 복구, 한국어/영어, data safety/privacy 근거 |

Release gate는 debug emulator만으로 종료하지 않는다. device Keystore 인증과 hardware 보안 수준, 저사양 Argon2 latency/OOM, rotate/process death/background, clipboard, external provider 쓰기 실패를 fixture로 확인한다. 첫판에 network decoder/ads/analytics를 넣지 않으면 permissions는 camera 요청과 필요한 플랫폼 기능으로 제한할 수 있다. 출시에 필요한 package/signing/data safety/privacy/store listing은 이후 합의한 단계에서 작성하며 지금 예약/게시하지 않는다.

## 7. 이번 조사 검증 기록

결과와 재현 명령은 [VALIDATION.md](VALIDATION.md)에 기록했다. **fixture 64개 통과**, host FFI build/Kotlin 생성 통과. Android ARM64 check는 target std 부재로 실패했고 실제 Android build/device/Keystore/16KB는 미검증이다. build/log/generated Kotlin은 gitignored `core/target/android-investigation/`에만 저장했다. fixture temporary storage와 Cargo download/cache도 이 worktree 내부다. 사용자 vault/secret/Keychain 및 운영 WebDAV에는 접근하지 않았다. `cargo test --workspace`, CLI/keyring smoke, Apple/Windows 전체 build를 실행하지 않았다.

## 8. 조사 당시 사용자에게 필요한 결정 (후속 승인으로 해소)

1. **기준/스택:** 최신 main을 기준으로 Kotlin/Compose + 기존 Rust/UniFFI/JNA, offline QR decoder, ARM64 중심, minSdk26으로 진행할지 (권장), minSdk23/32-bit까지 지원할지.
2. **보관/잠금:** 필수 master password + 선택 기기 인증 + background 즉시 잠금 + OS backup/D2D 제외/명시 암호화 백업만 허용할지 (권장), 편의성 중심의 자동 unlock/OS backup을 원할지. 후자는 별도 노출/복구 설계가 필요하다.
3. **첫판/후속:** 핵심 흐름만 먼저 (권장), 위젯 먼저, WebDAV 먼저 중 우선순위. Google migration의 첫판 제한(각 QR별 import, 배치 완전성 확인 미지원)을 수용할지, preview/완전한 multi-QR import가 필수인지.
4. **패키지:** `com.otpeek.app` / `dev.jiun.otpeek` / 사용자 지정. 출시 signing과 계정별 closed test 적용 여부 확인은 이후 사용자 로그인으로 진행한다.

위 결정 대기는 후속 사용자 승인으로 해소되었다. 실제 Android 구현은 `android/`에 한정하며, 기존 코어 API/crypto/vault format을 바꾸지 않는다. 이 문서의 작업량·출시 게이트는 production 준비가 완료됐다는 뜻이 아니다.

## 9. 구현 후 상태

`android/`의 수동/QR 등록, TOTP/HOTP 표시·복사, 암호화 저장, Keystore 선택 인증, SAF 암호화 백업/복구를 구현했다. ARM64 Rust·debug/release/R8 APK·AAB 빌드, JVM fixture 4개, ARM64 4KB(API35)/16KB(API36) 각 device fixture 7개와 모든 packaged ELF/ZIP/AAB 16KB 정렬 검사가 통과했다. 기존 64개 fixture 조사 결과와 feature 분리 후 host FFI 2개 재검증은 별도 기록한다.

확인된 빌드 문제 때문에 `otpeek-ffi`의 기존 default bindgen 기능을 유지하면서 Android library에서만 `--no-default-features`로 CLI generator를 제외했다. Rust `.rs` product/API/crypto/vault format은 변경하지 않았다. Android 전용 UniFFI 설정으로 API26–33에서 JNA cleaner를 사용하도록 생성해 lint API 문제를 해소했다. 패키지 문자열은 로컬 빌드용이며 Play 예약·게시·운영 signing은 실행하지 않았다. 세부 재현 명령/로그/미검증 항목은 [BUILD_VALIDATION.md](BUILD_VALIDATION.md)를 기준으로 한다. 위젯·WebDAV는 후속 우선순위 선택으로 남는다.

후속 2026-10-17: [확장 QA 결과와 남은 정책/실기기 결정](QA_20261017.md), [출시 준비 자료 초안](RELEASE_PREPARATION.md).
