# jiun 데스크톱의 Windows 설치 검증

**후속 갱신:** 아래 artifact/실행은 당시 이력이다. 현재 최종 preview와 runtime·리소스 보완 상태는 [SELF_CONTAINED_QA_20261025.md](SELF_CONTAINED_QA_20261025.md), WACK 원인 분석은 [WACK_FINDINGS_20261025.md](WACK_FINDINGS_20261025.md)를 따른다. Android 클립보드 정책 선택 대기는 사용자 위임으로 해소됐다.

**후속 발견:** 아래 개발 PC 실행은 .NET8이 이미 설치된 환경의 증거다. [WACK 원인 조사](WACK_FINDINGS_20261025.md)에서 preview의 외부 .NET 의존성을 발견했다. 자체 포함 패키징 보완은 로컬 수정·회귀 검사까지 완료했고 Windows 연결 복구 후 빌드 검증이 필요하다. 아래 과거 산출물을 독립 실행 가능한 최종 제출 후보로 취급하지 않는다.

사용자의 “jiun-test 말고 그냥 jiun 로그인하세요 (ssh jiun-home)” 지시에 따라 `jiun-home`의 **jiun / console session 1**에서 설치·실행 검증과 WACK를 수행했다. `jiun-test` 로그인 대기는 더 이상 차단 사유가 아니다. **Store 앱 identity 연결·제출·게시 완료는 아니다.**

## 기존 앱과 데이터 격리

실제 사용자 vault를 열지 않기 위해 기존 소스를 `F:/workspace/otpeek-msstore-20261024/desktop-fixture`에 따로 복사했다. 원본 worktree나 기존 Windows 앱은 수정하지 않았다.

- Fixture identity `OTPeek.LocalQA20261025`, publisher `CN=OTPeek Local QA 20261025`, 별도 protocol/file association을 사용했다. 실제 OTPeek 링크나 확장자 연결을 교체하지 않았다.
- 저장 폴더, legacy credential resource, 진단 로그와 instance key를 fixture 전용 이름으로 바꿨다. 위젯 COM ID도 별도로 지정했다. 이 격리를 위해 바뀐 C# 파일은 사전에 정한 **8개**뿐임을 hash 비교로 확인했다. fixture manifest는 별도 identity/version으로 구성했다. 제품 source에 이 경로 변경을 반영하지 않았다.
- 신규 경로에 공개 RFC TOTP/HOTP 계정과 신규 VMK만 생성했다. `jiun` CurrentUser DPAPI로 이 fixture VMK만 보호했다. 기존 vault/credential 항목을 읽거나 출력하지 않았다.
- 일회성 non-exportable 서명 키로 fixture MSIX를 서명하고 공개 인증서 신뢰를 검증했다. 개인 키는 내보내거나 출력하지 않았다. 이 인증서는 Store 인증서나 실제 앱 identity가 아니다.

## 발견해 해결한 실제 패키징 결함

위젯의 정상 카드 파일 `Templates/OtpWidgetTemplate.json`이 MSIX에 빠져 있었다. 초기 진단은 WindowsApps EXE 직접 실행의 access denied와 별도 build-output 진단의 template missing을 각각 기록했다. 설치본의 정확한 template 경로도 없음을 확인해 원인을 분리했다.

앞선 payload 검사는 `Templates/` 아래 아무 JSON만 있으면 통과했기 때문에 이 결함을 놓쳤다. 실제로 관계없는 deps/고지 JSON이 그 경로에 들어가 있었다. [앱 프로젝트](../../windows/Otpeek.App/Otpeek.App.csproj)는 카드 source를 정확한 고정 Link로 포함하도록 수정했고, [검사 도구](../../windows/scripts/verify-store-package.py)는 정확한 카드 파일명을 요구한다. decoy JSON이 누락을 가리지 못하는 회귀 사례를 추가해 **검사 도구 10개 테스트 통과**를 확인했다.

제품 preview와 격리 fixture를 모두 수정했다. 과거의 느슨한 payload 검사 통과를 위젯 실행 완료로 해석하면 안 된다. 이번 수정 이후 아래 실제 진단과 COM 검증이 기준이다.

## 완료한 실제 실행

| 항목 | 결과 | 근거 |
| --- | --- | --- |
| jiun에서 fixture MSIX 설치 및 앱 활성화 | **통과** | `desktop-interactive-result.json`, 설치 Status Ok / 창·공개 RFC 계정 표시 |
| 수정본 업데이트 | **통과** | fixture `2.0.1.0 → 2.0.2.0`, 공개 계정 유지. `desktop-upgrade-interactive-result.json` |
| 실제 packaged UI 수동 계정 등록 | **통과** | 공개 seed와 `Manual fixture`만 입력. `desktop-manual-account-result.json` |
| 앱 재열기·등록 계정 유지·DPAPI 자동 해제 | **통과** | 비밀번호 입력 없이 수동 추가 계정 재표시. `desktop-reopen-result.json` |
| 위젯 deployment/template/JSON/DPAPI/native vault 진단 | **통과** | 수정된 fixture 진단 exit0, 공개 TOTP 항목1개 읽음. 기존 사용자의 위젯 진단을 호출하지 않음 |
| 등록된 fixture 위젯 COM 활성화 | **통과** | native CoCreateInstance HRESULT0. `desktop-com-dpi-result.json` |
| 실행 프로세스 DPI | **PerMonitorV2 확인** | 실제 GetDpiAwarenessContextForProcess 비교와 EXE embedded manifest 확인 |
| 최종 제품 preview SDK unpack/정확한 payload | **통과** | 내부 package4개 native 검증, 정확한 widget card 포함. `package-receipt-template.json`, `payload-check-template.log` |
| 검증 후 정리 | **완료** | QA package uninstall, 임시 trust/private key 제거, owned task10개 제거. `desktop-cleanup-result.json` |

설치 단계에서 계정명 문자열의 SID 매핑 실패는 정확한 로컬 사용자 SID로 해결했다. PowerShell Activator 기반 COM 확인은 실패했지만, native CoCreateInstance로 같은 등록을 확인해 HRESULT0을 얻었다. 같은 identity/version의 다른 내용 설치는 `0x80073CFB`로 거부됐으므로 fixture version을 올린 정상 업데이트로 검증했다. 이러한 초기 실패를 성공으로 계산하지 않았다.

시스템 clipboard는 읽거나 교체하지 않았다. 카드 데이터·COM 통과는 Widgets Board에 사용자가 실제로 pin한 시각적 화면 검증이나 clipboard history UI 검증을 대신하지 않는다. 전원 재부팅·OS 계정 복구, 장치별 성능·접근성, 모든 파일 제공자의 picker UI도 이번 실행 범위로 완료 처리하지 않는다.

## WACK 결과와 해석

수정 전·후 격리 설치본에서 WACK를 실제 실행했다. 수정 후 보고서 `desktop-wack-fixed.xml`의 **24항목 중 PASS21 / 선택 FAIL2 / WARNING1, 필수 FAIL0**이다. appcert exit0은 실행 완료를 뜻하므로 전체 검사 PASS로 표시하지 않는다.

- 선택 검사 **58 FAIL**: SDK의 `Microsoft.UI.Xaml.winmd`/`Microsoft.UI.winmd`에서 Windows.UI 인터페이스와 중복 GUID를 지적했다.
- 선택 검사 **88 FAIL**: Windows App SDK bootstrap/RestartAgent, 앱·위젯 apphost의 실행 API와 SDK DLL 내부 문자열을 지적했다. 프로세스 실행 기능을 은폐하거나 SDK 파일을 제거하지 않았다.
- 필수 검사 **92 WARNING**: 도구가 `Otpeek.exe`를 처리하지 못했다고 보고했다. 별도 native 검사에서 EXE의 `PerMonitorV2` 선언과 실제 실행 프로세스의 PerMonitorV2 상태를 모두 확인했다. 경고를 임의로 PASS로 바꾸지 않았다.

Microsoft는 Desktop Bridge의 optional 검사를 정보성으로 설명한다. 이 사실은 로컬 보고서의 실패를 삭제하거나 실제 Store 인증을 보장하는 근거가 아니다. 최종 실제 Store identity/artifact로 재검토할 사항이다. [Microsoft Desktop Bridge 검사 설명](https://learn.microsoft.com/en-us/windows/uwp/debug-test-perf/windows-desktop-bridge-app-tests).

## 산출물과 보존

**최신 제품 preview**는 version `2.0.1.0`, placeholder `Otpeek` / `CN=Otpeek`이며 제출용으로 사용할 수 없다.

- 크기 **57,183,695 bytes**.
- SHA-256 `0284df058c6466ac2680dd2891ecf3b0a75e1e91ce84e038f50c871ca505905d`.
- 로컬 `.tools/msstore/artifacts/OTPeek-2.0.1.0-x64-PREVIEW-template-fixed.msixupload`.
- Windows `F:/workspace/otpeek-msstore-20261024/windows/Otpeek.App/AppPackages/Otpeek.App_2.0.1.0_x64_bundle.msixupload`.

**서명된 fixture**는 다른 identity/version `OTPeek.LocalQA20261025 / 2.0.2.0`다. 로컬 `OTPeek-LocalQA-2.0.2.0-signed.msix`와 공개 `.cer`는 QA 증거로만 보존했다. 테스트 후 trust와 non-exportable private key는 제거했으므로 이후 설치 신뢰가 자동 유지된다고 약속하지 않는다. 기존 source, 고지 원문·기존 QA evidence·과거 preview들은 보존했다. 작은 암호화 public fixture vault는 복구 증거로 별도 경로에 남겼다.

증거는 `.tools/msstore/evidence/`와 Windows 작업 경로의 `evidence/`에 있다. 서명 개인 키나 실제 사용자 데이터를 포함하지 않는다. 격리 준비·서명·interactive task·WACK·cleanup 스크립트는 ignored `.tools/msstore/`에 보존했다. 다른 프로젝트의 작업 폴더·프로세스·인증서는 변경하지 않았다.

현재 출시 차단은 **Partner Center의 실제 OTPeek Name/Publisher/PublisherDisplayName·기존 버전 확인과 운영/스토어 공개 정보·제출 검토**다. 브라우저 접근 오류와 Android 정책·실기기 항목은 별도로 남는다. 더 이상 다른 Windows 테스트 계정 로그인을 요청하지 않는다.
