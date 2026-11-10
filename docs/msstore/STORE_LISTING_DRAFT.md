# OTPeek Microsoft Store 문구 초안

로컬 검토용이다. Partner Center에 저장하거나 게시하지 않았다. 아래 공개 문구는 최종 Windows 설치·UI·QR·위젯 검증 후 제출 artifact와 대조한다. Android·Apple 기능을 Windows 기능으로 합산하지 않는다.

## 한국어

표시 이름 제안: OTPeek

짧은 소개: Windows에서 사용하는 TOTP와 HOTP 인증 코드, 암호화 보관함과 파일 백업.

설명 초안:

OTPeek은 일회용 인증 코드를 Windows PC에서 관리하는 앱입니다. 수동 입력이나 지원하는 OTP QR 형식으로 계정을 등록하고, TOTP와 HOTP 코드를 확인하고 복사할 수 있습니다. 계정은 공유 Rust 코어의 암호화 보관함에 저장하며, 비밀번호로 보호한 파일 백업과 복구를 지원합니다.

HOTP는 코드를 사용할 때 카운터가 증가합니다. 오래된 백업을 복구하면 이전 카운터가 되살아날 수 있으므로 복구 후 해당 서비스와 상태를 확인하세요. 비밀번호 분실과 PC 교체에 대비해 암호화 백업을 별도로 보관하세요.

## English

Proposed display name: OTPeek

Short description: TOTP and HOTP codes for Windows, with an encrypted vault and file backups.

Draft description:

OTPeek manages one-time authentication codes on your Windows PC. Add accounts manually or from supported OTP QR formats, then view and copy TOTP and HOTP codes. Accounts are stored in an encrypted vault using the shared Rust core. Password-protected file backups let you restore your accounts.

Using an HOTP code advances its counter. Restoring an older backup can restore an earlier counter, so check the account with its service after recovery. Keep an encrypted backup separately in case you lose your password or replace your PC.

## 개인정보 안내에 반영할 Windows 동작

- OTP 계정과 비밀키는 로컬 암호화 vault에 저장한다. Windows 사용자 범위의 DPAPI로 VMK를 보호하므로, Windows 계정과 PC 접근을 보호해야 한다. 이 사실을 매번 생체인증을 요구한다는 의미로 표현하지 않는다.
- Favicon 기능은 발급자나 계정명에서 추정한 도메인을 Clearbit/icon.horse/Google 요청 URL에 포함할 수 있다. 요청은 네트워크 주소 등 통신 메타데이터를 수신자에게 노출한다. 전송 없는 완전 오프라인 앱이라는 설명을 사용하지 않는다.
- WebDAV를 구성하면 선택한 서버와 암호화 vault를 송수신한다. 서버 주소·인증 정보와 실패 로그의 보관 및 표시를 최종 설정 흐름과 대조한다. iCloud가 Windows에서 지원된다고 쓰지 않는다.
- 복사한 코드는 시스템 클립보드로 전달된다. history/roaming 비활성 옵션과 소유 clip만 삭제하는 동작은 fixture11개로 확인했다. OS clipboard 전체의 접근 차단이나 다른 앱의 사본 제거를 보장하지 않는다.
- 기존 위젯은 저장된 VMK를 이용해 코드를 읽는다. 앱 잠금·Windows 잠금 중 노출 범위와 HOTP 동작을 전용 fixture 사용자에서 확인한 후 기능 설명과 심사 노트에 포함한다.
- 기존 코어의 삭제 tombstone과 외부 백업 잔존을 고려한다. 즉시 물리 삭제, 완전한 메모리 소거, 개발자의 비밀번호 복구를 보장하지 않는다.

코드 근거: [SecureStorageService](../../windows/Otpeek.Core.Windows/Services/SecureStorageService.cs), [FaviconService](../../windows/Otpeek.Core.Windows/Services/FaviconService.cs), [WebDavSyncBackend](../../windows/Otpeek.Core.Windows/Services/WebDavSyncBackend.cs), [ClipboardService](../../windows/Otpeek.Core.Windows/Services/ClipboardService.cs), [위젯 데이터 공급자](../../windows/Otpeek.Widget/OtpWidgetDataProvider.cs).

## 제출 전에 채울 항목

사용자 위임에 따른 준비 기본값은 검증된 x64/Windows11 우선, 한국어·영어 문구, 신규 상품이면 무료·한국/미국 우선이다. 기존 Store 상품의 가격/시장 정책은 실제 계정 값을 먼저 대조해 유지하며 계정에 변경을 저장하지 않았다. ARM64/x86은 검증 후 확장한다. Partner Center의 실제 OTPeek Identity Name/Publisher/PublisherDisplayName·기존 버전과 운영 주체·연락처·공개 개인정보 URL은 인증 후 실값을 대조한다. 위 문구는 개인정보처리방침 완성본이나 제출 설문 자동 답안이 아니다.

스크린샷은 전용 fixture 사용자에서 새 패키지를 실행해 촬영한다. 수동 등록/계정 목록, QR 등록, 암호화 백업·복구, 위젯을 보여주되 실제 사용자 계정·비밀키·복구 코드가 있는 기존 화면을 재사용하지 않는다. WACK·UI 검증 결과와 제한을 심사 노트에 반영한 뒤 제출 자료를 검토한다.
