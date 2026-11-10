# OTPeek Microsoft Store 출시 준비

**최신 결과:** [자체 포함 후속 QA](SELF_CONTAINED_QA_20261025.md)에서 .NET8 runtime 포함, 격리 QA widget의 내부 coreclr 실행, runtime 고지, 배율 리소스 누락 수정, 최종4개 MSIX native 무결성 및 synthetic15개를 확인했다. Windows SSH는 복구됐지만 현재 대화형 세션은 jiun-test라 새 앱 UI 재확인은 jiun 로그인 후에만 진행한다. 실제 Store identity 연결/계정 인증/제출은 남아 있다. [WACK 잔여3건 분석](WACK_FINDINGS_20261025.md)은 선택 FAIL2/도구 WARNING1의 근거를 기록한다. 아래 날짜별 내용은 이력이다. Android 클립보드 선택 대기는 [정책 반영·회귀](../android/CLIPBOARD_QA_20261025.md)로 해소됐다.

2026-10-23 기준으로 기존 WinUI Windows 앱의 MSIX 경로를 사용해 출시를 준비한다. 이 단계는 로컬 조사와 제출 준비이며, Store 식별자 확정·예약·업로드·심사 제출·게시를 수행하지 않았다. Android 클립보드 정책은 사용자 위임에 따라 반영했다.

**2026-10-24 갱신:** Windows 접속이 복구돼 별도 경로에서 x64 MSIX upload 생성, 내부 4개 패키지 native 무결성, 위젯 포함 검사 및 실제 패키지 DLL의 FFI fixture 검증을 완료했다. 기존의 “Windows build 미검증/호스트 offline” 문장은 10월 23일 이력이다. 현재 결과와 남은 사용자 단계는 [최신 Windows 검증](QA_20261024.md), 공개 문구는 [스토어 초안](STORE_LISTING_DRAFT.md)에 있다. Store identity는 여전히 placeholder이며 제출·출시는 완료하지 않았다.

추가로 실제 Windows 서비스/QR/WebDAV/sync assertion 34개와 고지 포함 preview 생성을 완료했다. 고지 asset 외 실행 바이너리 149개는 기존 검증본과 바이트 동일하다. 현재 남은 사용자 단계와 Safari 창 접근 오류도 위 최신 검증에 기록했다.

**2026-10-25 최신:** Windows 앱 클립보드의 공식 history/roaming 옵션과 소유 항목만 자동 삭제하도록 수정하고 새 packaged fixture 11개 assertion을 통과했다. 최종 preview 해시·빌드·현재 차단 상태는 [10월 25일 후속 검증](QA_20261025.md)이 기준이다. 이전 preview들은 증거로 남겨두며 제출에 사용하지 않는다.

**jiun 데스크톱 실행 완료:** 사용자 지시에 따라 `jiun-home`의 현재 `jiun` 세션에서 격리 서명 패키지 설치·업데이트·UI 수동 등록·재열기·위젯 COM·WACK를 실행했다. 추가로 실제 widget card 누락을 수정했으므로 **최신 artifact와 정확한 결과는 [데스크톱 검증](DESKTOP_QA_20261025.md)이 기준**이다. `jiun-test` 로그인은 더 이상 필요한 단계가 아니다. WACK는 PASS21 / 선택 FAIL2 / WARNING1로 기록하며 Store 인증 완료로 표시하지 않는다.

## 작업 범위와 기준

작업 위치는 `/Users/jiun/workspace/otpeek-android`, 기준 HEAD는 `54ee0bf`다. Android의 미커밋 변경이 있는 worktree이므로 Windows 제품 코드 수정 전에 Windows 전용 branch/worktree와 반영할 기준 커밋을 정한다. 원본 `/Users/jiun/workspace/otpeek`의 Windows 삭제 변경을 복구하지 않는다. `jiun-mbp:calex`의 작업은 이 작업의 빌드 환경이나 OTPeek 작업이라고 가정하지 않으며 원격 접속·메시지 전송·작업 변경을 하지 않았다.

현재 호스트는 Darwin ARM64이며 PATH에서 `dotnet`, `pwsh`, `msbuild`가 발견되지 않았다. Windows 빌드·설치·WACK 결과는 **미검증**이다. Android 통과 기록은 Windows 검증을 대체하지 않는다.

## 확인한 기존 구현

| 항목 | 코드 근거 | 출시 준비 상태 |
| --- | --- | --- |
| Store 패키징 | [package-msix.ps1](../../windows/scripts/package-msix.ps1), `-Mode Store` | StoreUpload와 로컬 서명 비활성화 경로 존재. 실제 산출물 생성은 미검증 |
| 패키지 식별자 | [Package.appxmanifest](../../windows/Otpeek.App/Package.appxmanifest) | `Name=Otpeek`, `Publisher=CN=Otpeek`, version `2.0.1.0`. 기존 릴리스 안내도 placeholder로 명시. Partner Center와 연결 필요 |
| 앱과 위젯 | [Otpeek.App.csproj](../../windows/Otpeek.App/Otpeek.App.csproj) | WinUI, Windows App SDK 1.8, .NET 8. MSIX 모드에서 위젯 빌드·payload 복사 경로 존재 |
| 네이티브 코어 | [Otpeek.Interop.csproj](../../windows/Otpeek.Interop/Otpeek.Interop.csproj) | Rust MSVC DLL 및 UniFFI C# 재사용. x64/ARM64/x86 매핑 존재. 아키텍처별 실제 패키지 검증 필요 |
| 기존 CI | [ci-windows.yml](../../.github/workflows/ci-windows.yml) | Release x64 일반 앱 빌드와 settings 테스트. MSIX Store bundle·위젯·WACK 통과 증거는 아님 |
| 키 저장 | [SecureStorageService.cs](../../windows/Otpeek.Core.Windows/Services/SecureStorageService.cs) | CurrentUser DPAPI VMK 보호. Store identity 변경·업데이트·재설치의 데이터 경로 검증 필요 |
| 네트워크 | [FaviconService.cs](../../windows/Otpeek.Core.Windows/Services/FaviconService.cs), [WebDavSyncBackend.cs](../../windows/Otpeek.Core.Windows/Services/WebDavSyncBackend.cs) | favicon 요청 대상에 계정에서 추정한 domain이 포함될 수 있음. WebDAV는 별도 원격 경로. Android의 오프라인 설명을 복사하지 않음 |
| 클립보드와 위젯 노출 | [ClipboardService.cs](../../windows/Otpeek.Core.Windows/Services/ClipboardService.cs), [WidgetProvider.cs](../../windows/Otpeek.Widget/WidgetProvider.cs) | Windows 자체 동작·잠금 중 코드 노출·history/roaming 차단·자동 정리를 fixture로 검증해야 함. Android 정책을 자동 적용하지 않음 |

Manifest는 `runFullTrust`, `internetClient`, `userAccountInformation`, 시작 작업, URI/file 연결 및 위젯 COM 등록을 선언한다. 실제 사용 근거와 제출 설명을 맞추되 조사만으로 권한을 삭제하지 않는다. 기존 `AppPackages/*_Test` 파일은 현재 HEAD의 Store 제출 산출물로 간주하지 않는다.

## 빌드와 검증 순서

1. 다른 작업과 겹치지 않는 Windows 작업 환경·checkout을 지정하고, VS/Windows SDK/UAP 위젯 도구·.NET SDK·Rust MSVC target을 확인한다. 실제 사용자 vault와 DPAPI 키를 열지 않고 fixture 전용 Windows 사용자 환경을 사용한다.
2. Partner Center에서 사용자가 확인한 OTPeek Identity Name, Publisher, PublisherDisplayName, 기존 Store 버전을 받는다. 계정 비밀번호·토큰·개인 키는 문서나 명령 출력에 남기지 않는다. 기존 sideload와 Store identity 차이에 따른 저장 경로·업데이트·복구를 검증한다.
3. 먼저 x64 단일 아키텍처로 아래 명령의 결과와 로그를 확보한다. `Store` 모드는 로컬 패키지 생성이며 자동 제출 명령은 아니다.

   ```powershell
   dotnet test tests/Otpeek.Core.Tests/Otpeek.Core.Tests.csproj -c Release
   ./windows/scripts/package-msix.ps1 -Mode Store -Platforms x64
   ```

4. MSIX manifest의 최종 identity/version, Rust DLL과 앱·위젯 PE 아키텍처, 위젯 실행 파일·templates·이미지 포함 여부를 검사한다. 생성된 `.msixupload`와 내부 bundle을 확인하고 SHA-256을 기록한다. 복수 아키텍처 명령은 각 아키텍처 빌드와 bundle 포함 여부를 확인한 뒤 사용한다.

현재 placeholder manifest로 로컬 QA만 수행하려면 위 Store 명령에 `-PreviewIdentity`를 명시해야 한다. 일반 Store 모드는 placeholder를 restore/build 이전에 거부한다. 이 옵션은 제출 가능한 identity라는 확인을 우회하지 않으며 산출물을 제출 후보로 바꾸지 않는다.
5. 별도 fixture 사용자에서 설치·실행·업데이트·제거, 수동/QR 등록, RFC TOTP/HOTP, counter 저장·재실행, 암호화 백업/복구 실패 보존, 프로토콜·파일 연결, 위젯·잠금·복사, DPI·키보드·접근성을 검증한다. 네트워크 fixture는 통제된 endpoint만 사용한다.
6. Windows App Certification Kit 결과를 확보한다. ARM64를 지원 대상으로 선택하면 ARM64에서도 네이티브 실행을 검증한다. Win10 지원은 manifest 선언만으로 완료 처리하지 않고 실제 지원 범위·위젯 가용성을 명시한다.
7. 검증된 실제 기능과 네트워크 처리에 맞춰 한국어·영어 스토어 설명, fixture 스크린샷, 개인정보처리방침, 연령 등급, 권한 설명과 심사 노트를 준비한다. 기존 [RELEASE.md](../RELEASE.md)의 공통 플랫폼 문구는 Windows 기능 검증 후 조정한다.

## 사용자 결정과 필요한 조작

- **Windows 환경:** 접근 가능한 테스트 머신/VM과 작업 경로. 다른 muxa 작업을 사용할 경우 그 작업과 경로를 명확히 지정한다.
- **기준 코드:** 원본의 삭제 변경을 유지한 채 Windows 전용 worktree를 만들 기준 커밋과, 다른 Windows 개발 결과를 포함할 범위.
- **Store 계정:** 로그인은 사용자가 처리한다. OTPeek 등록/예약 현황과 공개 package identity 값을 확인한다.
- **지원 범위:** x64 우선 출시 또는 x64+ARM64, 최소 Windows 버전과 위젯 지원 범위.
- **공개 정보:** 운영 주체·문의처·개인정보 URL, 가격·지역·언어·출시 일정. favicon 네트워크 전송과 잠금 중 위젯 노출을 어떻게 안내/설정할지 검토한다. 기존 정책은 이 단계에서 바꾸지 않는다.
- **제출:** 검증 산출물과 스토어 초안 검토 후 업로드·심사·게시 단계의 실행 범위를 별도 확인한다.

## 이번 검사 결과

Windows project XML과 manifest 파싱은 통과했다. Manifest의 명시적 Assets 경로를 대상으로 파일 존재를 검사했다. 이 검사는 MSBuild payload 계산·PRI 리소스·Store 인증을 대신하지 않는다. 제품 코드·기존 workflow·앱 식별자와 다른 worktree는 변경하지 않았다.

### Windows 빌드 경로 확인과 패키지 검사

2026-10-23 후속 조사에서 `jiun-mbp:calex`의 보고와 README/패키징 스크립트를 읽기 전용 확인했다. Calex는 `jiun-home`의 `F:/workspace/calex`에서 빌드하며, Store 패키징은 로컬 서명을 비활성화한다. 세션에는 게시자 표시명을 수정한 패키지가 Store 재제출 후 인증 중이라는 보고가 있다. 이는 OTPeek 서명·빌드 완료 증거가 아니며 Calex identity·키·산출물을 복사하지 않았다.

이 Mac → `jiun-home` LAN SSH, `jiun-mbp` → `jiun-home` LAN SSH, 이 Mac → 등록된 Tailscale DNS SSH는 모두 연결 시간 초과였다. Tailscale 조회에서도 `jiun-home`은 offline, LastSeen `2026-10-22T18:43:35.1Z`였다. SSH 설정·네트워크·다른 세션은 변경하지 않았다. PC 전원/네트워크/SSH 복구를 사용자에게 요청했으며, 연결 전에는 새 Windows 빌드·WACK·서명 완료로 보고하지 않는다. 연결 후 별도 빌드 경로를 사용하며 기존 `F:/workspace/calex`나 기존 OTPeek 사용자 저장소를 사용하지 않는다.

저장소의 기존 `OtpAuthenticator.App_1.0.0.0_x64.msix`, `1.0.1.0` 패키지를 ZIP으로 검사했다. 두 파일 모두 identity가 `OtpAuthenticator` / `CN=OtpAuthenticator`이며 `otpeek_ffi.dll`, `Otpeek.Widget.exe`가 없어 현재 제출 후보로 사용할 수 없다. 내용이나 서명을 수정하지 않았다.

[verify-store-package.py](../../windows/scripts/verify-store-package.py)는 새 실제 산출물의 upload → bundle → package를 열어 기대 identity/version/publisher display name, 아키텍처 집합, Rust DLL/앱/위젯 PE 아키텍처, 위젯 파일·templates·등록 및 개인 키 파일 확장자 혼입을 검사한다. 명시적으로 제공한 identity와의 일치만 확인하며, 그 값이 Partner Center에 등록됐다는 사실을 인증하지 않는다. ZIP 구조 검사이므로 MakeAppx의 native integrity, WACK, 코드 서명 신뢰 및 런타임 테스트를 대신하지 않는다.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 windows/scripts/test_verify_store_package.py -v
python3 windows/scripts/verify-store-package.py <new.msixupload> \
  --name <PartnerCenterName> --publisher '<PartnerCenterPublisher>' \
  --display-name '<PartnerCenterPublisherDisplayName>' \
  --version 2.0.1.0 --architecture x64
```

공개 synthetic ZIP/PE fixture **8개 통과**: 정상 nested upload, 올바른 bundle에 숨은 stale identity, native DLL 누락, native 아키텍처 불일치, 개인 키 확장자 파일, placeholder identity, 미빌드 아키텍처, 게시자 표시명 불일치. 실제 사용자 데이터·인증서 저장소는 사용하지 않았다. 이 검사는 Windows 제품 기능 테스트 결과로 합산하지 않는다.

## Microsoft 공식 기준

2026-10-23 열람 기준이다. MSIX Store 제출은 Partner Center 앱 등록과 연결된 identity를 사용하며, Store는 인증 후 패키지를 다시 서명한다. 제출용 CA 인증서 구매를 선행 조건으로 삼지 않는다. 로컬 sideload 설치 신뢰와 Store 서명은 각각 검증한다. [MSIX 패키지 요구사항](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/app-package-requirements).

MSIX upload에는 아키텍처별 패키지 또는 bundle이 포함될 수 있다. [Visual Studio 패키징](https://learn.microsoft.com/en-us/windows/msix/package/packaging-uwp-apps). 이름 예약 이후 제출에는 패키지뿐 아니라 가격·가용성, 속성, 연령 등급과 스토어 자료 등이 필요하다. [MSIX 제출 체크리스트](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/create-app-submission?pivots=store-installer-msix).
