# OTPeek Microsoft Store 문구 초안

2026-11-12 Partner Center 상품 `9P1X6RLW8RXP`, Submission 1의 en-us·ko-kr listing 초안에 아래 문구를 저장하고 서버 재열기로 네 필드의 exact match를 확인했다. 게시·최종 제출은 하지 않았다. 스크린샷이 없어 listing은 Incomplete다. 최종 Windows 설치·UI 검증 후 제출 artifact와 대조한다. Android·Apple 기능을 Windows 기능으로 합산하지 않는다.

## 한국어

표시 이름: OTPeek

짧은 소개: TOTP·HOTP 인증 코드와 암호화 보관함, 비밀번호로 보호하는 백업·복구.

설명:

OTPeek은 Windows PC에서 일회용 인증 코드를 관리하는 앱입니다. 수동 입력이나 지원하는 OTP QR 이미지로 계정을 등록하고 TOTP·HOTP 코드를 확인하고 복사할 수 있습니다. 계정은 로컬 암호화 보관함에 저장하며 비밀번호로 보호한 파일 백업과 복구를 지원합니다.

HOTP 코드를 보거나 복사하는 것만으로 카운터가 증가하지 않습니다. 카운터를 진행하려면 다음 코드 기능을 사용하세요. 오래된 백업을 복구하면 이전 카운터가 복원될 수 있으므로 해당 서비스와 계정 상태를 확인하세요. 비밀번호 분실과 PC 교체에 대비해 암호화 백업을 별도로 보관하세요. 개발자는 마스터 비밀번호를 재설정할 수 없습니다.

선택적으로 WebDAV 동기화를 설정하면 지정한 서버와 암호화 보관함을 주고받습니다. 계정 아이콘 기능은 발급자나 계정 정보에서 추정한 도메인을 사용해 외부 이미지 서비스에 요청합니다. 이 기능은 설정에서 끌 수 있습니다.

Product feature: 수동·QR 계정 등록, TOTP·HOTP 코드, 로컬 암호화 저장과 비밀번호로 보호하는 백업·복구.

Developed by: Jiun Bae

## English

표시 이름: OTPeek

짧은 소개: TOTP and HOTP codes with an encrypted vault and password-protected backups.

설명:

OTPeek manages one-time authentication codes on your Windows PC. Add accounts manually or from supported OTP QR images, then view and copy TOTP and HOTP codes. Accounts are stored in an encrypted local vault. Password-protected file backups let you restore your accounts.

Viewing or copying an HOTP code does not advance its counter. Use the next-code action when you need to advance it. Restoring an older backup can restore an earlier counter; check the account with its service after recovery. Keep an encrypted backup separately in case you lose your password or replace your PC. The developer cannot reset your master password.

Optional WebDAV sync transfers your encrypted vault to the server you configure. Optional account icons request external image services using domains inferred from issuer or account information; you can disable this in Settings.

Product feature: Manual and QR account setup, TOTP/HOTP codes, encrypted local storage, and password-protected backup and restore.

Developed by: Jiun Bae

## 개인정보 안내에 반영할 Windows 동작

- OTP 계정과 비밀키는 로컬 암호화 vault에 저장한다. Windows 사용자 범위의 DPAPI로 VMK를 보호하므로, Windows 계정과 PC 접근을 보호해야 한다. 이 사실을 매번 생체인증을 요구한다는 의미로 표현하지 않는다.
- Favicon 기능은 발급자나 계정명에서 추정한 도메인을 Clearbit/icon.horse/Google 요청 URL에 포함할 수 있다. 요청은 네트워크 주소 등 통신 메타데이터를 수신자에게 노출한다. 전송 없는 완전 오프라인 앱이라는 설명을 사용하지 않는다.
- WebDAV를 구성하면 선택한 서버와 암호화 vault를 송수신한다. 서버 주소·인증 정보와 실패 로그의 보관 및 표시를 최종 설정 흐름과 대조한다. iCloud가 Windows에서 지원된다고 쓰지 않는다.
- 복사한 코드는 시스템 클립보드로 전달된다. history/roaming 비활성 옵션과 소유 clip만 삭제하는 동작은 fixture11개로 확인했다. OS clipboard 전체의 접근 차단이나 다른 앱의 사본 제거를 보장하지 않는다.
- 기존 위젯은 저장된 VMK를 이용해 코드를 읽는다. 앱 잠금·Windows 잠금 중 노출 범위와 HOTP 동작을 전용 fixture 사용자에서 확인한 후 기능 설명과 심사 노트에 포함한다.
- 기존 코어의 삭제 tombstone과 외부 백업 잔존을 고려한다. 즉시 물리 삭제, 완전한 메모리 소거, 개발자의 비밀번호 복구를 보장하지 않는다.

코드 근거: [SecureStorageService](../../windows/Otpeek.Core.Windows/Services/SecureStorageService.cs), [FaviconService](../../windows/Otpeek.Core.Windows/Services/FaviconService.cs), [WebDavSyncBackend](../../windows/Otpeek.Core.Windows/Services/WebDavSyncBackend.cs), [ClipboardService](../../windows/Otpeek.Core.Windows/Services/ClipboardService.cs), [위젯 데이터 공급자](../../windows/Otpeek.Widget/OtpWidgetDataProvider.cs).

## 제출 전에 채울 항목

사용자 위임에 따른 준비 기본값은 검증된 x64/Windows11 우선, 한국어·영어 문구, 신규 상품이면 무료·한국/미국 우선이다. 기존 Store 상품의 가격/시장 정책은 실제 계정 값을 먼저 대조해 유지하며 계정에 변경을 저장하지 않았다. ARM64/x86은 검증 후 확장한다. 실제 identity와 공개 연락처·URL을 확인하고 Properties 초안을 저장했다. [2026-11-12 실행 기록](STORE_IDENTITY_DRAFT_20261112.md)을 현재 상태의 기준으로 삼는다. 위 문구는 개인정보처리방침 완성본이나 제출 설문 자동 답안이 아니다.

스크린샷은 전용 fixture 사용자에서 새 패키지를 실행해 촬영한다. 수동 등록/계정 목록, QR 등록, 암호화 백업·복구, 위젯을 보여주되 실제 사용자 계정·비밀키·복구 코드가 있는 기존 화면을 재사용하지 않는다. WACK·UI 검증 결과와 제한을 심사 노트에 반영한 뒤 제출 자료를 검토한다.
