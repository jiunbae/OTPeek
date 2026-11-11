# DPAPI 및 새 Windows 패키지 UI 재검증 — 2026-11-11

**후속 .NET10 전환:** 아래 검증은 .NET8 fixture2.0.3.0의 이력이다. 새 LTS 소스·패키지와 UI 대기는 [전환 결과](NET10_LTS_20261111.md)를 따른다.

## 실행 명령과 핵심 출력

```text
ssh -o BatchMode=yes -o ConnectTimeout=8 -o ControlPath=none jiun-home 'whoami; query session'
jiun-home\jiun; console jiun 1 Active
# query session 자체 exit1이지만 세션 행과 후속 검증으로 확인했다.

python3 .tools/msstore/run-remote.py .tools/msstore/recheck-dpapi-20261111.ps1
user=jiun; sessionId=1; publicInputOnly=true; roundtrip=true; protectedBytes=230

python3 .tools/msstore/run-remote.py .tools/msstore/prepare-ui-20261111.ps1
PASS fresh temporary non-exportable QA signature; fixture version2.0.3.0 retained

python3 .tools/msstore/run-remote.py .tools/msstore/schedule-ui-resume-20261111.ps1
# 후속 selector 수정 후 같은 task 재실행
LastTaskResult=0; recovery-result-classified.json: 모든 기록된 UI 항목 true

python3 .tools/msstore/run-remote.py .tools/msstore/schedule-manual-resume-20261111.ps1
LastTaskResult=0; manualRegistration=true; persistedAfterRestart=true; dpapiAutoUnlock=true

python3 .tools/msstore/run-remote.py .tools/msstore/finalize-resume-20261111.ps1
fixtureUninstalled=true; temporaryTrustRemoved=true; temporaryPrivateKeyRemoved=true
ownedTasksRemoved=4; publicFixtureDataAndEvidenceRetained=true

haejo open-url https://partner.microsoft.com/dashboard/windows/overview --helper ...
page_not_shown; loaded_verified=false
haejo windows com.apple.Safari --helper ...
Sign in to your account; https://login.microsoftonline.com/common/oauth2/v2.0/authorize
haejo observe com.apple.Safari --window-id 9710 --helper ...
Sign in; email/phone/Skype input; Next button
```

마지막 URL 명령은 인증 리디렉션 때문에 목적 URL 도착 확인에 실패했다. 후속 창·폼 관측으로 Microsoft 로그인 화면을 확인했다. Safari에 해당 창을 열어 두었고 인증값 입력·제출은 하지 않았다. 브라우저의 다른 탭 내용과 인증 쿼리는 증거로 보존하지 않는다.

## 이번 판정과 증거

| 검사 | 결과 |
| --- | --- |
| jiun 일반 권한 대화형 session1 CurrentUser DPAPI 공개3바이트 roundtrip | PASS. fresh probe에서 이전 Access denied가 재현되지 않음 |
| recovery fix가 포함된 격리 MSIX 2.0.3.0 설치·실행 | PASS. 실제 제품 identity나 사용자 vault 변경 없음 |
| 읽을 수 없는 VMK → master password UI | PASS. 공개 fixture VMK 끝1byte만 시험용으로 손상시키고 원래 암호문은 private evidence에 보존 |
| 잘못된 master password | PASS. 거부하고 fixture vault hash 유지 |
| 올바른 master password → 기존 RFC/Manual 계정 표시 | PASS |
| 재시작 후 DPAPI 자동 해제·기존 계정 유지 | PASS |
| 새 수동 계정 등록·재시작 후 유지 | PASS. 공개 RFC seed 및 Resume fixture 20261111만 사용 |
| 검색·Backup & Restore·Settings·All Accounts 복귀 | PASS. 설정 변경이나 실제 export/import는 실행하지 않음 |
| coreclr/clrjit/hostfxr/hostpolicy | 네 모듈 모두 설치된 fixture package 내부에서 로드 |
| QA 정리 | 소유 앱 프로세스·설치·임시 trust/private key·task4개 제거. fixture 데이터·복구 증거 보존 |

실제 jiun 데스크톱에서 Windows UIAutomation으로 조작했다. 최초2회는 검색 wrapper의 ValuePattern 미지원, 다음에는 계정 수가 붙은 All Accounts의 완전 일치 selector 때문에 harness가 실패했다. 검색의 자식 Edit와 prefix가 일치하는 선택 가능한 navigation item으로 좁혀 같은 task를 재실행했고 최종 LastTaskResult=0 및 성공 JSON을 확인했다. 제품 코드 수정은 필요하지 않았다. 수동 등록 harness 생성의 최초 로컬 Python SyntaxError는 전송 전에 수정하여 해당 실패 시 원격 조작은 없었다. Windows evidence의 과거 error JSON은 이력이며 최종 성공 JSON과 task 결과를 판정 근거로 삼는다.

Mac 증거: `.tools/msstore/evidence/dpapi-roundtrip-20261111.json`, `ui-recovery-pass-20261111.json`, `ui-manual-pass-20261111.json`, `ui-cleanup-20261111.json`. Windows 증거: `F:/workspace/otpeek-msstore-20261024/evidence/ui-resume-20261111/`. 새 harness·scheduler는 ignored `.tools/msstore/*resume*20261111.ps1`에 보존했다. 실제 사용자 vault·비밀·기존 clipboard는 사용하지 않았다.

## Store 제출 준비와 미완료

현재 preview는 여전히 `Otpeek / CN=Otpeek` placeholder, 2.0.1.0, 90,120,396 bytes, SHA256 `55169b285e5e9414b56ba5a7085b5d0c6f3dc3ef93c1ba080ca1c271f0c74093`다. 이번 격리 fixture는 Store 제품 identity가 아니다. 업로드·심사 제출은 실행하지 않았다.

직접 조작이 필요한 항목은 Safari의 **Microsoft Partner Center 로그인**(필요하면 MFA 및 올바른 developer account 선택)이다. 인증 후 실제 상품 identity/publisher·기존 version·listing/연락처/공개 privacy URL을 대조하고 실제 identity의 최종 패키지를 생성·필요 검증하여 기존 승인된 제출을 이어간다. 사용자에게 질문은 보내지 않았다.

기존 runtime 유지보수 gate도 남는다. 현재 preview는 self-contained .NET8.0.33이다. [Microsoft 최신 지원 표](https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core)에서 .NET8 지원 종료2026-11-10·최종 patch8.0.34와 .NET10 LTS 지원 지속을 확인했다. 현재 preview를 장기 유지보수 가능한 최종판으로 취급하지 않는다. .NET10 LTS 전환과 WinUI/Interop/packaging 회귀는 별도 기술 스택 변경으로 합의·검증해야 하며 이번에 임의 구현하지 않았다.

이번 통과가 OS 전체 DPAPI 데이터 복구·모든 UI 조합·새 QR picker·백업 파일 picker end-to-end·전체 WACK·실제 Store identity 인증 통과를 증명하지는 않는다. 이미 완료한 전체 테스트와 WACK는 불필요하게 반복하지 않았다. 테스트 프로세스와 임시 설치는 정리했고 Microsoft 로그인 창은 열어 두었다.

## 대신 선택한 사항과 불확실성

기존 최종 recovery fixture를 재사용하고 QA용 non-exportable 인증서만 새로 만들었다. 공개 fixture VMK만 시험 대상으로 삼아 완료 후 자체 변경을 정리했다. 정상화가 재부팅·PIN 재인증·복원 키 중 어느 요인 때문인지 분리하지 못했다. 기존 암호화 키 복원을 추가 변경하지 않고 성공한 공개 DPAPI roundtrip과 실제 UI를 근거로 진행했다.

기존 감시는 온라인 복귀를 감지했으나 detach 후 Tend CLI가 pane을 식별하지 못해 알림에 실패했다. 사용자의 직접 재개 후 감시 PID66568을 종료했다. 감시 알림이 성공했다고 주장하지 않는다.
