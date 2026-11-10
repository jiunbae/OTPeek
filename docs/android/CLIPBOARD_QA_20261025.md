# Android 클립보드 정책 및 회귀 — 2026-10-25

사용자가 정책 선택을 best practice로 위임하고, 앱 전환 후 붙여넣기와 최대 30초 후 자기 항목만 삭제하도록 요청했다. 기존 코어·vault 포맷·Keystore·HOTP counter 계약은 변경하지 않았다. 사용자 vault/기기/시스템 clipboard는 사용하지 않고, 별도 OTPeek AVD의 공개 RFC fixture만 사용했다.

## 현재 동작과 한계

- 앱 전환 시 vault 잠금은 유지하고 복사한 OTP는 즉시 지우지 않는다. HOTP는 복사 후 30초, TOTP는 30초와 코드의 남은 유효시간 중 짧은 시간에 삭제를 시도한다. 반복 복사는 이전 타이머를 취소하며 경과 시간은 monotonic clock으로 측정한다.
- sensitive flag와 매 복사별 UUID를 넣는다. 만료 시 현재 항목의 UUID가 자기 것일 때만 삭제한다. 다른 앱에서 새로 복사한 내용은 보존한다. 회전 때 Activity를 바꿔도 process singleton의 소유권/타이머는 유지한다. 명시적 잠금 버튼은 접근 가능한 자기 항목을 즉시 지운다.
- **30초 삭제를 모든 상태에서 보장할 수는 없다.** Android10 이상은 포커스 없는 일반 앱의 clipboard 읽기를 제한한다. 소유권을 확인하지 못하면 무조건 삭제하지 않고, 포커스 복귀 시 만료된 자기 항목을 확인해 정리한다. 프로세스 종료/OS 스케줄링도 자동 정리를 막거나 늦출 수 있다. 이 한계를 한국어/영어 앱 안내에 표시했다. sensitive flag는 다른 앱의 붙여넣기를 차단하는 접근제어가 아니다.

이는 “다른 복사 내용을 지우지 않는다”를 보존하는 구현이다. background/process death까지 정확히 30초 삭제와 소유권 확인을 동시에 보장하는 공개 Android API는 이 구현에서 확보하지 못했다. 추가 권한/overlay/상시 서비스를 도입하지 않았다. [Android10 clipboard 제한](https://developer.android.com/about/versions/10/privacy/changes#clipboard-data), [공식 sensitive/cleanup 지침](https://developer.android.com/privacy-and-security/risks/secure-clipboard-handling).

## 실제 검증

| 검사 | 결과 | 근거 |
| --- | --- | --- |
| Debug APK / test APK / R8 release APK / AAB / lintDebug | 통과, lint 0 errors / 12 warnings | `.tools/logs/clipboard-policy-build.log`, `android/app/build/reports/lint-results-debug.txt` |
| API35 / Android15 / ARM64 4KB | 9개 통과, 55.840초 | `.tools/logs/clipboard-policy-api35.log`: ClipboardPolicyTest7 + UiFlowTest2 |
| API26 / Android8 / ARM64 4KB | 7개 통과, 50.076초 | `.tools/logs/clipboard-policy-api26.log`: ClipboardPolicyTest7 |
| API36 / Android16 / ARM64 16KB | 7개 통과, 68.586초 | `.tools/logs/clipboard-policy-api36.log`: ClipboardPolicyTest7 |

7개 정책 사례는 별도 test-APK UID에서 앱 전환 후 실제 읽기, 회전 후 유지, TOTP 조기 만료, 다른 앱 교체 후 만료/복귀 시 보존, 배경 만료 후 포커스 복귀 정리, 재복사 시 낡은 타이머 취소, 만료 코드 복사 거부·명시 잠금, HOTP 30초 정리를 검증한다(마지막 복합 동작은 한 테스트에 포함). UiFlowTest2는 배경 vault 잠금·붙여넣기 유지·HOTP counter/회전과 기존 UI 동작을 확인한다.

API26 첫 준비 시도는 남은 offline TCP transport 및 구형 AVD 이름 property 차이로 설치 전에 중단했다. owned endpoint만 재연결하고 legacy/console AVD 이름 확인을 추가한 뒤 동일 fixture 검사를 실행했다. 이를 앱 실패나 테스트 통과로 계산하지 않았다. 모든 소유 AVD는 종료했다. 다른 프로젝트 ADB/AVD를 중단하지 않았다.

재현: `bash android/scripts/gradle-local.sh :app:assembleDebug :app:assembleDebugAndroidTest :app:assembleRelease :app:bundleRelease :app:lintDebug`. 별도 fixture AVD에서 두 APK를 설치한 뒤 `bash android/scripts/adb-fixture.sh shell am instrument -w -r -e class com.otpeek.app.ClipboardPolicyTest,com.otpeek.app.UiFlowTest com.otpeek.app.debug.test/androidx.test.runner.AndroidJUnitRunner`. API26/36은 ClipboardPolicyTest만 선택했다. 기존 전체 RFC/백업/5-OS suite는 변경과 무관하므로 반복하지 않았다.

## 남은 출시 게이트

클립보드 정책 선택 대기는 해소됐다. 실기기/OEM에서 배경 제한·프로세스 종료·키보드/clipboard UI를 포함한 기기 검증과 기존 인증/복구 출시 게이트는 남는다. APK/AAB는 로컬 검증 산출물이며 Play 식별자·운영 서명·계정별 testing/production 접근·스토어 공개 정책의 검토 및 제출 완료가 아니다. [기존 출시 준비](RELEASE_PREPARATION.md).
