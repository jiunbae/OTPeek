# 커밋·푸시 및 Windows 제출 시도 — 2026-11-10

사용자가 변경사항 커밋·푸시, 열린 `jiun-home`에서 새 Windows 패키지 UI 검증, Microsoft Store 제출까지 명시적으로 승인했다. 이전의 push/제출 금지는 이 요청 범위에서 해소됐다. 이번 결과는 **Git 반영 완료, Windows UI 부분 검증 및 결함 수정, Store 인증 대기·미제출**이다.

## Git 및 비밀 검사

기존 Android/Windows 출시 준비 변경241파일을 `85a0f02`로 커밋하고 `origin/feat/android-bootstrap-20261013`에 푸시했다. 원격 branch SHA와 로컬 HEAD 일치를 확인했다. 원본 worktree의 삭제 변경, 다른 프로젝트, main branch는 변경하지 않았다.

커밋 스킬의 staged 검사는 공개 RFC seed URI와 Kotlin/C#/Rust의 입력 변수·타입 선언도 민감 값으로 표시했다. 표시된 파일을 직접 검토했다. gitleaks 기본 검사5건도 같은 공개 RFC4226/6238 seed였다. **해당 seed 문자열만 정확히 허용한 검사에서 누출0건**을 확인했다. 실제 비밀번호·토큰·개인 키는 커밋하지 않았다. Gradle wrapper 무결성과211패키지 고지/원본 MPL 소스의 SHA-256도 확인했다. 원문 고지의 공백과 Gradle Windows 스크립트의 CRLF는 원문 그대로 보존했다.

## 재현한 출시 결함과 최소 수정

Windows `jiun`/session1 Active를 확인했다. 별도 `OTPeek.LocalQA20261025` identity와 공개 fixture 데이터만 사용했다. 이전 VMK 파일이 존재하지만 DPAPI로 읽을 수 없는 경우, `OpenWithStoredKey()`는 `InvalidOperationException`을 던진다. 앱 시작부는 기존에 `OtpException`만 잡아 마스터 비밀번호로 넘어갔으므로 실제 UI가 `Vault error`에 머물렀다.

`App.xaml.cs`의 해당 호출에 `InvalidOperationException` 처리만 추가하여 기존 비밀번호 재시도 루프로 넘긴다. vault/crypto/DPAPI 보호 방식·키 포맷은 바꾸지 않았다. 평문 키 저장이나 임의의 보호 우회도 도입하지 않았다.

## 실제 검증 결과

| 항목 | 결과 | 근거 (`.tools/msstore/evidence/`, 원격 작업 경로 `evidence/`) |
| --- | --- | --- |
| x64 제품·fixture 빌드 | 통과 | 원격 `selfcontained-ui-20261110/recovery-build-{production,fixture}.log`, `final-production-build.log` |
| 격리 fixture 서명·설치·업데이트 | 통과,2.0.3.0 | 원격 `selfcontained-ui-20261110/recovery-install.json`, sign verify log |
| 새 패키지 창 표시 | 통과 | `recovery-result-classified-20261110.json` |
| 패키지 내부 runtime 사용 | 통과 | hostfxr/hostpolicy/coreclr/clrjit 모두 fixture install path에서 로드 |
| 읽을 수 없는 VMK → 마스터 입력 UI | **수정 후 통과** | 같은 classified 결과 |
| 잘못된 마스터 입력 | **거부·vault hash 유지 통과** | 같은 classified 결과 |
| 올바른 마스터 뒤 계정 표시·재실행 자동 해제 | **환경 차단 / 미완료** | `Access is denied.`, publicAccountsVisible=false, reopen NOT_VERIFIED |
| 앱과 독립된 DPAPI 공개 샘플 | **실패 재현** | `ui-environment-probe-20261110.json`: jiun/session1의 별도 일반 권한 task, 공개3바이트 Protect/Unprotect에서 Access denied. 동일 task의 fixture 디렉터리 쓰기는 성공 |
| 새 제품 MSIX bundle | 통과, 내부4개 package native 무결성 | `package-receipt-recovery-20261110.json` |
| runtime·위젯·배율 payload | 통과 | `payload-check-recovery-20261110.log`, scale125/150/200/400·.NET8.0.33·원본 고지 매핑 |
| 정리 | 완료 | `cleanup-result.json`: own package/process/task, 임시 trust 및 non-exportable machine private key 제거, 공개 fixture 복구 데이터 보존 |

처음 CurrentUser 인증서 생성도 NTE_PERM으로 실패했다. 임시 QA 인증서만 machine store의 별도 provider에 만들고 정상 서명·설치를 확인한 뒤 개인 키까지 제거했다. 서비스 SSH 컨텍스트의 패키지 업데이트도 거부되어 jiun 대화형 task에서 성공했다. elevated QA 프로세스가 남은 동안 일반 권한 재활성화가 다른 PID로 전달되는 시도도 성공으로 계산하지 않았다. 자기 프로세스만 종료하고 일반 권한으로 재시도했다.

DPAPI 차단은 **이번 대화형 scheduled-task 환경에서 독립 샘플로 재현한 범위**다. 모든 jiun 앱/일반 직접 실행 세션의 DPAPI가 고장났다고 확대하지 않는다. 내부 원인·프로필 복구 방법은 아직 확정하지 못했다. Windows 사용자 보안 저장소의 권한/키를 임의로 변경하거나 테스트 결과를 통과로 바꾸지 않았다. 수정 후 분류는 `PARTIAL_ENVIRONMENT_BLOCKED`이며 전체 UI PASS가 아니다.

## 현재 preview

- 제품 version2.0.1.0 / x64 / placeholder `Otpeek / CN=Otpeek`.
- **90,120,396 bytes**, SHA-256 `55169b285e5e9414b56ba5a7085b5d0c6f3dc3ef93c1ba080ca1c271f0c74093`.
- Windows 보존본: `F:/workspace/otpeek-msstore-20261024/evidence/selfcontained-ui-20261110/OTPeek-2.0.1.0-x64-PREVIEW-recovery-20261110.msixupload`.
- 로컬 보존본: `.tools/msstore/artifacts/OTPeek-2.0.1.0-x64-PREVIEW-recovery-20261110.msixupload`.

설치된 SDK가 이번 빌드에서 .NET8.0.33 patch를 선택했으므로 실제 복원 runtime pack에 맞춰 고지 inventory를 갱신했다. 다른210패키지의 고지 메타데이터는 동일하며 생성 순서 차이가 포함된다. .NET8 지원 종료일은2026-11-10이다. 이후 운영 버전은 지원되는 LTS 전환 검증이 필요하며 이번에 큰 framework 변경을 임의로 구현하지 않았다. [공식 .NET 지원 정책](https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core).

## Store 제출 상태와 다음 실행 조건

Safari에서 Partner Center를 실제 열었으며 Microsoft `Sign in to your account`의 입력 폼으로 이동했다. 로그인 완료를 사용자에게 요청했다. Vault에서 OTPeek/Microsoft 관련 항목 메타데이터와 기존 로그인 위임을 확인했지만 이 상품에 사용할 Partner Center 로그인 위임은 확인되지 않았다. 다른 프로젝트의 API 자격 증명을 대신 사용하지 않았다.

**업로드·심사 제출은 실행되지 않았다.** 실제 OTPeek Store identity·기존 상품/버전·공개 운영자 정보는 인증 후 확인해야 하며 placeholder를 업로드하지 않았다. 예약·계정 변경·결제/시장 변경도 하지 않았다. [Microsoft 제출 체크리스트](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/create-app-submission).

남은 직접 조건은 Partner Center 인증 및 Windows 테스트 세션의 DPAPI 정상화다. 이후 새 패키지의 실제 계정 표시·재실행과 최종 identity 산출물 검증을 마무리하고, 이미 승인된 Store 제출을 계속한다. Android 실기기 QA는 별도 기존 출시 게이트이며 이번 Windows 검증으로 대체하지 않는다. 기존 전체 RFC/5-OS/WACK를 반복하지 않았다.
