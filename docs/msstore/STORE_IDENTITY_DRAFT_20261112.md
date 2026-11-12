# Store identity와 제출 초안 — 2026-11-12

## 실행 명령과 핵심 출력

```text
# 전용 Safari window 26672, task t-5a8572e33a9740f096207e7e에서 실행
haejo run .tools/msstore/pc-reserve-approved-otpeek.json --helper --yes ...
# Reserve 1회 실행 뒤 generic commit_unverified: 자체 증명이 아니므로 서버 재열기
# Product overview / identity: OTPeek, 9P1X6RLW8RXP 생성 확인

# 실제 Product Identity 페이지를 읽고 manifest XML과 세 필드를 대조
Name=43097Maybe.OTPeek
Publisher=CN=AE9C9F32-5B23-43CB-831B-BD1967F7B403
PublisherDisplayName=Jiun Bae
# XML exact equality PASS; version 2.0.1.0 유지

haejo run .tools/msstore/pc-save-en-us.json --helper --yes ...
# target_uniqueness_unverified / effect=not_started; 클릭 실행 안 됨
# 같은 창·상품·locale URL을 확인한 Safari DOM 명령으로 유일한 Save 버튼 1회 클릭
python3 .tools/msstore/pc-dom.py < task-scoped-form-command
EN_US_SERVER_REOPEN_EXACT_FIELDS_PASS
KO_KR_SERVER_REOPEN_EXACT_FIELDS_PASS
PROPERTIES_SERVER_REOPEN_EXACT_FIELDS_PASS
# overview: Properties Complete; Store listings Incomplete; submission In draft

ssh -o BatchMode=yes -o ConnectTimeout=8 -o ControlPath=none jiun-home whoami
# exit255: connect to host 192.168.32.32 port22: Operation timed out

# Python AST 검사 후 분리 프로세스 시작, 중복 실행 flock
python3 .tools/msstore/release-watch-20261112/monitor.py
WATCHER_STARTED 74505
TMUX_PANE=%42 tend proc register --name otpeek-release-until2359 --pid 74505 ...
# registered; state WAITING_OFFLINE
```

## 확인한 결과

사용자 승인으로 정확한 이름 OTPeek을 1회 예약했다. Store ID는 `9P1X6RLW8RXP`, PFN은 `43097Maybe.OTPeek_zqjxq5gtnmbwr`이다. 계정 이메일이나 다른 상품의 publisher를 추측하지 않고 실제 Product Identity에서 읽은 세 값을 manifest에 반영했다. 기존 버전 2.0.1.0은 변경하지 않았다.

Submission 1 (`1152921505702382965`)을 초안으로 만들고 English (United States)와 Korean (Korea) listing을 저장했다. 두 언어의 description, shortDescription, product feature 1개, Developed by 네 필드를 새 서버 페이지에서 다시 읽어 입력값과 일치함을 확인했다. 최초 재열기 검사는 SPA 로드 전 필드 부재로 실패했으며, editor heading과 필드 준비 뒤 재확인했다. 문구의 실제 값은 [listing 기록](STORE_LISTING_DRAFT.md)에 있다. HOTP 보기/복사와 다음 코드 카운터 진행을 구분한다.

Properties에는 Security → Personal security, 개인정보 사용 Yes, 아래 공개 URL만 저장했다. OTP 계정명 등 개인 정보를 다루므로 Yes를 선택했다. 공개 지원 이메일 `jiunbae.dev@gmail.com`은 support 페이지에서 대조했다. 비공개 Partner Center 로그인 이메일·전화·주소를 고객 지원 필드에 옮기지 않았다.

- Website: https://jiun.dev/OTPeek/
- Privacy: https://jiun.dev/OTPeek/privacy.html
- Support: https://jiun.dev/OTPeek/support.html

공개 privacy/support 페이지를 다시 읽어 URL 접근과 연락처를 확인했다. 가격·시장·계정 설정은 변경하지 않았다. 최종 `Submit for certification`은 실행하지 않았다. Safari window 9710과 다른 탭은 조작하거나 닫지 않았다. Store 작업은 창을 전면 활성화하지 않고 진행했다.

## Windows 자동 대기와 검증 한계

이전 3시간 감시는 SSH timeout36회 후 12:58 KST에 EXPIRED였다. 이전 결과를 성공으로 바꾸지 않고 `.tools/logs/idle-ui-20261112/report.json`에 보존했다.

사용자가 연장한 새 감시는 오늘 **2026-11-12 23:59 KST / 14:59 UTC**까지만 5분마다 연결을 확인한다. 연결되면 실제 identity의 x64 Store 패키지 빌드와 native integrity/runtime/resource/QR binding 검증을 먼저 한다. 빌드 및 자동 fixture 프로세스는 보수적으로 항상 BelowNormal이다. 개인 화면 조작은 하지 않으며 자동 fixture는 공개 입력·임시 경로·in-memory clipboard만 사용한다. 공유 컴파일 서버 재사용을 끄는 설정은 해당 프로세스 환경에만 둔다. 이전 패키지·manifest 증거는 별도 위치로 보존한다.

실제 identity payload를 참조하는 Interop·Windows services·Clipboard fixture, Core settings 검사와 공개 3바이트 CurrentUser DPAPI roundtrip을 jiun의 hidden Limited interactive task에서 실행하도록 준비했다. 대화형 프로필이 없으면 빌드 이후 WAITING_DESKTOP으로 기다린다. 성공 receipt가 있으면 빌드·검사를 반복하지 않는다. 실패하면 해당 단계에서 멈추고 허브에 결과를 남긴다.

최종 UI는 별도 `OTPeek.LocalQA20261025` v2.0.5.0 fixture만 사용한다. 사용자 앱이 전면에 없고 입력이 **600초를 넘게** 없을 때만 시작한다. C# guard가 입력을 50ms마다 확인하고 새 입력·종료 시각 도달 시 자기 fixture 프로세스와 worker를 중단한다. 정리 단계는 자기 fixture·임시 인증서·task만 대상으로 한다. 실제 Store identity의 설치 UI와 같은 검증이라고 주장하지 않는다.

현재 실제 identity Windows 빌드·자동 fixture·최종 UI는 **호스트 오프라인으로 미실행**이다. 로컬 Python AST/XML 검사는 Windows PowerShell 구문·C# guard 컴파일·패키지 빌드 성공을 증명하지 않는다. 원격 연결 후 실행 전 PowerShell AST와 C# 컴파일을 검사하도록 했으며 결과를 `.tools/logs/release-watch-20261112/`에 기록한다. 이전 placeholder preview 패키지를 실제 Store artifact로 업로드하지 않는다. native 빌드가 끝나면 새 unsigned upload와 SHA256 receipt를 로컬에 회수한다.

## 최종 제출 전에 남은 것

- 실제 identity 패키지 빌드·무결성·자동 fixture 및 격리 v2.0.5.0 최종 UI 결과. 설치한 .NET이 없는 깨끗한 VM 및 모든 OS/아키텍처 통과를 주장하지 않는다.
- 실제 fixture 화면의 필수 스크린샷. 현재 Desktop0개여서 EN/KO listing은 Incomplete다. 그림을 가짜 앱 화면으로 대신하지 않는다.
- Age ratings 미시작, Packages 미업로드, Pricing/availability 미시작. 초안 보존은 유효한 제출/심사 통과의 증거가 아니다. 가격·시장 저장과 최종 Submit 전 허브에 보고하고 멈춘다.
- **공개 개인정보 문구와 코드의 불일치:** privacy.html §3는 issuer에서만 도메인을 추정하고 account name/email은 보내지 않는다고 설명한다. `FaviconService.ResolveInfo`는 accountName도 fallback으로 처리하고, 도메인처럼 보이는 accountName 전체 또는 비일반 메일 호스트를 요청 도메인으로 쓴다. 실제 외부 요청은 하지 않고 소스와 공개 문구만 대조했다. listing에는 발급자/계정 정보에서 추정한다고 보수적으로 썼다. 코드·공개 정책을 임의 변경하지 않았고 허브에 제출 게이트로 보고했다.
- 기존 mp:PhoneIdentity 값은 이번 세 필드 연결에서 변경하지 않았다. Product Identity에서 제공하지 않은 GUID를 만들어 넣지 않았으며 Store/native validation에서의 수용 여부는 미검증이다.

사용자 위임 아래 대신 선택한 것은 listing category/subcategory와 개인정보 사용 Yes, 항상 BelowNormal, 기존 x64/EN·KO 초안 유지다. 새 기능·새 운영 의존성·가격/시장·공개 정책 변경은 하지 않았다. 허브 전달 요청은 `req_18e73240549500f8_6`, 초안 완료·정책 불일치 보고는 `req_18e7327d340101b0_7`이다.
