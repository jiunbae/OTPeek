# Windows 번들 런타임 및 제출 준비 — 2026-10-25

**2026-11-10 후속:** 커밋·푸시와 새 Windows UI 검사, VMK 복구 오류 수정·환경 차단, 실제 Store 로그인 상태는 [최신 제출 시도](SUBMISSION_ATTEMPT_20261110.md)를 따른다. 아래 결과는 당시 기록이다.

사용자가 best practice 정책 선택을 위임한 후, 기존 .NET8/WinUI/Rust를 유지하면서 외부 .NET 설치 의존성과 증분 번들의 배율 리소스 누락을 수정했다. Store 계정/식별자에 접근하거나 제출하지 않았다. 다른 프로젝트와 원본 worktree의 Windows 삭제 변경을 건드리지 않았다.

## 완료 및 실제 근거

| 항목 | 결과 | 근거 (`.tools/msstore/evidence/`, 원격 `evidence/`) |
| --- | --- | --- |
| x64 제품 및 격리 fixture Store preview 빌드 | 통과 | `wack-audit/selfcontained-build-{production,fixture}.log` |
| .NET8 자체 포함 | coreclr/clrjit/hostfxr/hostpolicy/CoreLib, app/widget includedFrameworks8.0.32 확인. 외부 framework 요구 없음 | `payload-check-selfcontained-complete.log` |
| 정확한 MSIX 내부 QA widget 실행 | **통과, exit0**. `jiun` SSH/session0에서 외부 DOTNET_ROOT 경로·MULTILEVEL 탐색을 차단한 자식 프로세스만 실행. host trace가 payload 내부 coreclr 사용 확인 | `selfcontained-qa/headless-result.json`, `widget-corehost-trace.log` |
| 제3자 고지 | runtime pack을 포함해211패키지, 원문142개, 원본 MPL archive8개, 누락0 | `selfcontained-qa/notice-collection.log`, source `Assets/ThirdPartyNotices/index.json` |
| 증분 번들 리소스 회귀 | 고지 변경 후 incremental package에서 scale125/150/400 누락 발견. `--no-incremental`로 재생성해 네 embedded package 및 scale125/150/200/400 확인 | `selfcontained-qa/complete-bundle-build.log`, `package-receipt-selfcontained-complete.json`, `payload-check-selfcontained-complete.log` |
| 최종 native 무결성 | 제품 bundle의4개 package MakeAppx unbundle/unpack 통과 | `package-receipt-selfcontained-complete.json` |
| 회귀 도구 | **synthetic15개 통과**. .NET 누락/외부 의존/다른 architecture 및 scale 누락을 거부 | `store-payload-fixtures-final.log` |
| placeholder 제출 방지 | `-PreviewIdentity` 없는 Store 명령을 restore/build 전에 거부 | `selfcontained-qa/complete-artifact.json`, `identity-gate-complete.log` |
| 임시 서명/작업 정리 | 자기 QA trust와 non-exportable private key 삭제, queued task 제거, fixture package 미설치 확인 | `selfcontained-qa/cleanup-result.json` |

Runtime pack은 `project.assets.json`의 일반 `libraries`가 아니라 `downloadDependencies`에 있어 고지 수집에서 빠졌었다. `notice-inventory.ps1`은 선택한 shipping RID(기본 win-x64)의 runtime pack까지 읽는다. 기존 원문이 이미 deduplicate되어 있어 원문142개/보관 소스8개는 그대로이며 매핑과 README만 추가됐다. ARM64/x86을 추후 만들면 대응 RID를 명시해 고지도 다시 생성한다.

재빌드 후 **실행 관련379개 중378개는 이전 self-contained 제품과 바이트 동일**하다. 다시 컴파일된 `Otpeek.dll`은 hash가 바뀌었으므로 모든 binary가 같다고 표시하지 않는다. widget/core/vendor/runtime/deps/template은 동일하다. 위젯 진단은 사용자 vault 대신 `OTPeek.LocalQA20261025`의 공개 RFC fixture만 사용했다. global .NET 설치/설정이나 실제 앱 설치를 바꾸지 않았다. 이 검사는 .NET이 전혀 없는 깨끗한 VM에서 전체 앱 UI를 검증한 것과 같지 않다.

## 최종 로컬 검토 산출물

- x64 preview upload, **90,119,948 bytes**, version2.0.1.0.
- SHA-256 `018b3cc57d97dcfc0218e9ae8d0dc0f55d0e7a445dd2120c1b4ebfc1c767216a`.
- Windows 보존 위치: `F:/workspace/otpeek-msstore-20261024/evidence/selfcontained-qa/OTPeek-2.0.1.0-x64-PREVIEW-selfcontained-complete.msixupload`.
- 로컬 동일 SHA-256 보존본: `.tools/msstore/artifacts/OTPeek-2.0.1.0-x64-PREVIEW-selfcontained-complete.msixupload`.
- Identity는 **Otpeek / CN=Otpeek placeholder**. 제출 가능 상태가 아니다. 중간의 resource pack 없는 `814ce0...` preview나 runtime 없는 이전 preview를 제출하지 않는다.

Microsoft Store용 upload는 Store가 다시 서명하므로 운영 인증서를 임의로 만들지 않았다. QA에 사용한 별도 identity의 서명은 이미 실제 검증했고, 임시 키는 export하지 않고 제거했다. [공식 자체 포함 배포 설명](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/self-contained-deploy/deploy-self-contained-apps).

## 남은 직접 조작과 검증

이번 재확인의 `query session`은 **console jiun-test/session3 Active, jiun 대화형 세션 없음**이었다. `jiun-test`로 바꾸지 않고 `jiun` 전용 task를 취소·제거해 다음 로그인 때 예고 없이 앱을 실행하지 않도록 했다. 계정 사용 승인을 재요청하지 않는다. **jiun 대화형 로그인 후** 새 self-contained fixture의 설치/창 실행과 패키지 내 runtime module 경로 확인만 이어서 수행한다. 이전 버전의 실제 jiun UI 등록/업그레이드/COM/DPI 검증은 [기존 데스크톱 결과](DESKTOP_QA_20261025.md)에 보존하며 이번 새 artifact UI PASS로 대체하지 않는다.

Partner Center 로그인 후 실제 OTPeek Identity Name/Publisher/PublisherDisplayName·기존 버전을 연결하고 최종 package를 재생성해야 한다. 계정에 연결된 실제 운영 주체·문의처·공개 개인정보 URL을 대조해야 하며 값을 지어내지 않는다. 초안의 화면 자료도 공개 fixture UI로 촬영한다. 첫 제출 기술 범위는 검증된 x64/Windows11, 한국어·영어 문구로 준비하고, ARM64/x86 결과를 합산하지 않는다. 신규 상품의 공개 설정 초안은 무료·한국/미국 우선이며 기존 상품의 가격/시장 정책이 있으면 이를 먼저 대조한다. 추가 선호도 답변을 기다리지 않고 로컬 준비 기본값으로만 반영했다. 업로드/심사 제출/게시는 실행하지 않았다.

WACK58/88 SDK/apphost 선택 FAIL과92 도구 WARNING은 [분석 기록](WACK_FINDINGS_20261025.md)을 따른다. 원격 증거 JSON/XML/log는 로컬로 복사 완료했다. 전체 WACK를 반복하거나 이 결과를 새 패키지 전체 PASS로 표시하지 않았다. 실제 Store identity 산출물이 정해진 후 필요한 인증 검사를 실행한다. S Mode 지원은 미검증이다.

## 유지보수 시점

현재 포함된8.0.32는 2026-10-13 패치다. .NET8 지원 종료는 **2026-11-10**이며 자체 포함 앱은 앱 업데이트로 runtime 패치를 배포해야 한다. 이 이후까지 출시/유지가 이어지면 지원되는 LTS로 전환하고 WinUI/Interop/fixture 검증을 별도 수행해야 한다. 이번에는 기존 기술 스택을 임의로 대체하지 않았다. [Microsoft 지원 정책](https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core).
