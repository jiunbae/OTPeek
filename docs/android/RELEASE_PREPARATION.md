# Android 출시 준비 자료 — 2026-10-17

로컬 검토용 초안이다. 스토어/외부 사이트/계정에 전송하거나 게시하지 않았다. 아래는 현재 코드의 데이터 흐름 근거이며, 최종 개인정보처리방침·Data safety 제출 전에 운영 주체/문의 주소/공개 URL과 출시 artifact를 확정해야 한다.

**2026-10-25 정책 반영:** 사용자가 best practice 선택을 위임했다. [클립보드 구현·검증과 OS 한계](CLIPBOARD_QA_20261025.md)를 현재 기준으로 사용한다. 다른 앱에 붙여넣기 전에 보관함은 기존처럼 배경 진입 시 잠긴다.

## 데이터 보관과 접근 근거

| 데이터 | 사용/보관 | 전송·삭제·복구 한계 |
|---|---|---|
| OTP 비밀키, 계정명/발급자, HOTP counter | Rust AES-GCM 암호화 vault, 앱 private no-backup 저장소 | 앱 서버 전송 경로/INTERNET 권한 없음. 사용자가 고른 외부 파일 제공자에 암호화 백업을 저장할 수 있음 |
| vault/backup 비밀번호와 해제된 키 | 암호 해제에 필요한 프로세스 메모리. 앱 상태 저장/평문 preferences에 넣지 않음 | immutable String/FFI 복사까지 완전한 memory zeroization은 보장하지 않음. 비밀번호 분실 복구 서비스 없음 |
| 선택 기기 인증 | Android Keystore 인증형 non-exportable AES 키로 VMK wrapping | PIN/생체 템플릿은 앱이 읽지 않음. 새 기기/재설치/키 무효화 시 master 또는 명시 백업으로 복구 |
| 카메라 이미지/QR 문자열 | 사용자가 스캔을 열고 권한을 허용할 때 로컬 CameraX/ZXing → Rust URI parser | 이미지 파일 저장·서버 전송·QR 로그 없음. Google multi-QR 완전성은 보장하지 않음 |
| 복사한 OTP | sensitive 표시, 앱 전환 후 유지. HOTP 30초/TOTP 남은 유효시간과 30초 중 짧은 시점에 앱 소유 clip 삭제 시도 | Android 배경 읽기 제한 시 소유권을 확인할 수 없어 포커스 복귀 후 정리. 프로세스 종료 시 자동 삭제 보장 불가. 다른 앱의 새 복사 내용 보존 |
| 삭제 계정 | 코어의 기존 tombstone 계약으로 목록에서 숨기고 암호화 vault에 유지 | 90일이 지난 tombstone은 이후 저장 시 purge. 즉시 물리 삭제나 정확히 90일 후 자동 삭제를 약속하지 않음. 기존 외부 백업은 사용자가 별도로 삭제 |

근거: `android/app/src/main/AndroidManifest.xml`, `res/xml/{backup_rules,data_extraction_rules}.xml`, `VaultRepository.kt`, `VaultKeyStore.kt`, `VaultViewModel.kt`, `QrScanner.kt`, `ClipboardGuard.kt`, `core/crates/otpeek-ffi/src/lib.rs::delete_account`, `otpeek-vault/src/lib.rs::{to_bytes,purge_tombstones}`. 삭제 안내에도 보관 기간/백업 잔존을 명시했다. 암호화 파일이 삭제되어도 flash/OEM/외부 제공자의 forensic 완전 삭제를 보증하지 않는다.

앱 삭제/데이터 지우기는 로컬 앱 저장소와 기기 키를 사용할 수 없게 만든다. OS cloud/D2D backup은 제외했고 사용자 명시 암호화 파일 백업만 제공한다. 외부 제공자가 cloud 동기화하는 경우 그 제공자의 계정/보관 정책이 적용된다. 앱 계정 생성/원격 회원 DB/분석/광고/위치·연락처·기기 식별자 수집 코드는 이 첫판에 없다. 이 기술 근거를 Google Play 설문 전체의 자동 답안이나 심사 통과 보장으로 취급하지 않는다.

## 공개 문구 초안

> OTPeek은 TOTP/HOTP 계정을 기기에 암호화하여 저장하는 인증 앱입니다. 수동 입력과 QR 등록, 코드 복사, 비밀번호로 암호화된 파일 백업·복구를 지원합니다. 비밀번호와 백업 파일을 안전하게 보관하세요. 비밀번호를 잃으면 개발자가 복구할 수 없습니다. 기기 분실·앱 삭제 전 백업이 필요합니다. 기기 간 자동 동기화와 홈 위젯은 이번 버전에 포함하지 않습니다.

개인정보 안내 초안: OTP 계정과 비밀키는 기기의 암호화 보관함에서 처리합니다. 카메라는 사용자가 선택한 QR 스캔에만 사용하며 이미지를 보관하거나 서버로 전송하지 않습니다. 사용자가 선택한 파일 제공자에 암호화 백업을 내보낼 수 있습니다. 복사한 코드는 시스템 클립보드에 전달됩니다. 계정 삭제 후에도 기존 코어의 보관 규칙에 따라 암호화 삭제 항목과 외부 백업이 남을 수 있습니다. 운영 주체·문의 주소·공개 정책 URL은 사용자 확정 전까지 초안이며 앱이나 Play에 임의로 게시하지 않습니다.

Google Play는 개발자가 실제 데이터 처리와 SDK 동작을 투명하게 설명하고 공개 개인정보처리방침/Data safety를 제공하도록 요구한다. 최종 공개 정책에는 주체와 문의 방법, 접근 데이터/사용 목적/보관·삭제 정책을 포함해야 한다. [공식 User Data 정책](https://support.google.com/googleplay/android-developer/answer/10144311). 계정 삭제 웹페이지 규칙은 앱이 **앱 계정 생성**을 지원하는 경우의 적용 여부를 따로 확인한다. OTP에 저장한 다른 서비스의 계정을 OTPeek 서버 계정으로 오인하지 않는다.

## 기기 QA 및 게시 전 체크

- [ ] 전용 실기기 모델/Android 버전 확인, 사용자 vault가 없는 debug 패키지로 fixture만 테스트
- [ ] strong biometric 등록/변경/취소·lockout, PIN/password 인증, reboot 및 key invalidation 후 master 복구
- [ ] 카메라 권한 거부/재허용, 실제 QR/Google export 모든 QR, 회전·foreground/background·process death
- [ ] 기기 파일 제공자와 cloud 제공자의 백업/복구·부분 쓰기/취소, 빈 기기 v1/v2와 기존 기기 merge/replace
- [ ] 저사양 Argon2 지연/OOM, 큰 글꼴/작은 화면, TalkBack 실제 읽기 순서/버튼 동작, 한국어 문구
- [ ] OEM cloud/D2D에서 no-backup 및 키 이전 제외, uninstall/reinstall 후 명시 파일 복구
- [ ] 최종 package 이름/운영 주체/문의 주소/개인정보처리방침 공개 URL 확정
- [ ] 운영 signing/키 보관·복구 담당 확정, 계정별 closed test/production 접근 요건 사용자 로그인으로 확인
- [ ] release artifact 기준 target36/ARM64/16KB 및 permission·의존 SDK 재확인 후 스토어 자료 검토

위젯/WebDAV와 multi-QR 완전성 추적은 최초 승인된 후속 범위를 유지한다. 기본 crypto/포맷 변경이나 서버/결제/새 운영 서비스 도입으로 이 검증 항목을 우회하지 않는다.
