# WACK 잔여 항목 조사와 런타임 보완

Store 로그인과 독립적으로 선택 FAIL58/88과 DPI WARNING92를 조사했다. 전체 WACK를 반복하지 않고 **92번만 최소 native 대조 앱과 기존 격리 QA 앱에서 각 1회** 실행했다. 제품 코어·암호화·정책 변경은 없다.

| 항목 | 분류와 확인 근거 | 영향과 처리 |
| --- | --- | --- |
| 58 메타데이터 | SDK 원본 winmd의 Microsoft.UI와 Windows.UI 타입 GUID 중복. 앱이 만든 타입을 지적하지 않는다. | SDK 수준의 선택 검사로 기록. SDK 파일 삭제·GUID 변조·임의 업그레이드로 숨기지 않는다. |
| 88 차단된 실행 파일 | 원본 SDK의 실행 API/문자열과 기본 .NET apphost의 ShellExecuteW. | Desktop Bridge 선택 항목이며 S Mode는 별도 미검증이다. 외부 .NET 설치 의존성을 발견해 자체 포함 패키징으로 수정·payload/격리 widget 실행 검증 완료. |
| 92 DPI | PerMonitorV2 manifest의 최소 native 앱에서도 같은 EXE 처리 실패 경고 재현. 실제 OTPeek 프로세스의 PerMonitorV2는 기존 실행 증거에 있음. | 현재 WACK/OS 환경의 처리 경고로 분류. 내부 처리 실패의 세부 원인은 미확인이고 결과를 PASS로 바꾸지 않는다. |

## SDK와 apphost 원본 대조

제품 preview의 `Microsoft.UI.Xaml.winmd`는 복원된 WinUI NuGet 파일과 SHA-256이 같고 Authenticode가 Valid였다. `Microsoft.UI.winmd`도 Windows App SDK Runtime **1.8.260710003 x64 MSIX 내부 파일**과 정확히 일치하며 Microsoft 서명이 유효했다. GUID 중복은 이 SDK 파일의 타입들에 해당한다. 이 사실만으로 upstream의 설계 의도까지 추정하지 않는다.

88번에 나온 DirectML, DWriteCore, Xaml Controls, SDK.NET, onnxruntime, WinRT.Runtime, WinUIEdit, RestartAgent, WindowsAppRuntime 및 네 아키텍처의 Bootstrap DLL도 복원 패키지 원본 또는 내부 runtime MSIX와 hash가 일치했다. `WindowsAppSdk.AppxDeploymentExtensions.Desktop.dll`은 Runtime1.8.260710003 x64 MSIX까지 추적했다. PRI는 실행 파일이 아니므로 Authenticode 부재를 변조로 판정하지 않았다.

`Otpeek.exe`와 `Otpeek.Widget.exe`의 PE `.text`는 stock .NET apphost 후보 중 각 1개와 byte-identical이고, import table은 각 2개 후보와 같았다. 두 EXE의 `SHELL32.dll!ShellExecuteW`는 원본 호스트에도 있는 import다. 제품 C# source에서는 Process.Start/ShellExecute/CreateProcess/cmd.exe/powershell.exe 호출을 찾지 못했다. **앱이 작성한 외부 명령 실행 경로가 확인되지 않았다는 범위**이며 SDK 내부의 모든 동적 경로가 실행 불가능하다는 증명은 아니다.

Microsoft는 Desktop Bridge optional 검사와 onboarding 기준을 구분하고, 앱에 포함된 파일에 대한 blocked-executable 항목의 해석도 설명한다. 이를 S Mode 지원이나 Store 인증 보장으로 확대하지 않는다. [공식 검사 설명](https://learn.microsoft.com/en-us/windows/uwp/debug-test-perf/windows-desktop-bridge-app-tests).

원격 증거: `F:/workspace/otpeek-msstore-20261024/evidence/wack-audit/{vendor-provenance,nested-vendor-provenance,bootstrap-provenance,apphost-audit}.json`. 연결 복구 후 JSON/XML/log 전체를 로컬 `.tools/msstore/evidence/wack-audit/`로 복사했다.

## DPI 대조 실험

WACK는 `10.0.26100.6584`다. 별도 `OTPeek.DpiControl20261025` 패키지에 최소 C++ wWinMain만 넣고, 기존 앱과 같은 PerMonitorV2 manifest를 VC 도구로 embed했다. SDK mt.exe로 내장 manifest를 다시 추출했다. 이 control에는 WinUI·.NET·Rust·vault 코드가 없다.

`jiun` 활성 session1에서 `appcert test -testid '[92]'`만 native control과 기존 `OTPeek.LocalQA20261025`에 각각 실행했다. 두 보고서 모두 test1개/index92이며 같은 “EXE 처리 실패 / DPI 인식 안 됨” WARNING이었다. 처음 숫자만 넘긴 CLI는 -1로 종료돼 보고서가 없었고, 검사 성공으로 계산하지 않았다. 문서화된 bracket 형식으로 고친 결과만 비교했다.

이 재현과 기존 실제 process DPI 검사는 앱의 DPI 선언 누락보다 해당 검사 환경의 처리 문제를 뒷받침한다. **검사기 내부의 정확한 실패 원인과 다른 OS/도구 버전의 동작은 미확인**이다. 최종 Store identity/artifact의 인증 결과도 별도다.

원격 증거는 `wack-audit/native-dpi-result.json`, `qa-dpi-result.json`, 각 XML/log, control source/extracted manifest다. 비교 후 두 패키지·두 임시 trust/private key·owned task를 제거했다. `cleanup-result.json`으로 확인했고 개인 vault를 읽지 않았다.

## 실제 출시 결함과 수정 상태

apphost 경로를 조사하면서 최신 preview에 .NET runtime 본체가 없음을 발견했다. `coreclr.dll`, `clrjit.dll`, `hostfxr.dll`, `hostpolicy.dll`, `System.Private.CoreLib.dll`이 없고 앱·위젯 runtimeconfig가 외부 `Microsoft.NETCore.App 8.0.0`을 요구한다. manifest에도 이를 설치하는 .NET8 framework dependency가 없다. .NET이 설치된 개발 PC의 성공은 깨끗한 Windows에서의 독립 실행 증거가 아니었다.

`WindowsAppSDKSelfContained=true`는 Windows App SDK 배포만 제어한다. Microsoft도 .NET 앱은 .NET self-contained 배포가 별도로 필요하다고 설명한다. [공식 지침](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/self-contained-deploy/deploy-self-contained-apps).

로컬 수정은 기존 .NET8을 MSIX에 포함하는 범위다.

- [패키징 스크립트](../../windows/scripts/package-msix.ps1): SelfContained/단일 플랫폼 RID 지정, 위젯 restore에도 같은 설정.
- [앱 프로젝트](../../windows/Otpeek.App/Otpeek.App.csproj): RID가 있을 때 그 위젯 출력 디렉터리 사용. 예전 framework-dependent 파일의 우연한 재사용 방지.
- [검사 도구](../../windows/scripts/verify-store-package.py): runtime DLL 존재·아키텍처, 앱·위젯 includedFrameworks, 외부 framework 의존성 부재 검사.

새 runtime 회귀와 배율 리소스 회귀를 포함한 **synthetic 검사15개 통과**. 기존 runtime 없는 실제 preview는 강화된 검사에서 거부되어 결함을 재현했다. 이어 실제 Windows x64 제품/격리 fixture 빌드, 외부 .NET 탐색을 차단한 정확한 QA widget 실행, 패키지 내부 coreclr host trace 검증을 완료했다. .NET runtime pack 고지도211패키지 inventory에 포함했다.

고지 후 증분 재패키징에서 scale125/150/400 누락을 발견해 `--no-incremental`로 수정했다. 최종 upload의4개 embedded package native 무결성과 scale125/150/200/400, runtime/template/architecture 검사가 통과했다. 최종 hash·증거·제약은 [자체 포함 후속 QA](SELF_CONTAINED_QA_20261025.md)가 기준이다. 이전 artifact를 제출 후보로 사용하지 않는다.

현재 남은 실행 조건은 **jiun 대화형 로그인**이다. 최신 실제 세션은 jiun-test만 Active였으므로 해당 계정으로 대신 검증하지 않았다. jiun SSH에서는 격리 widget 진단이 통과했지만 새 managed 앱 UI는 다시 실행하지 못했다. 이전의 host offline/미전송 상태는 해소됐다. Partner Center 실제 identity 및 인증, 최종 artifact의 Store 인증은 별도다. 전체 WACK/RFC는 반복하지 않았다.
