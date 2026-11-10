# jiun-home DPAPI 복구 진행 — 2026-11-10

## 실행 명령과 핵심 출력

원격 명령은 이 worktree의 `.tools/msstore/run-remote.py`로 전달했다. 공개 입력 `[1,2,3]`만 암호화/복호화했고 실제 사용자 vault·브라우저·Credential Manager 데이터는 열지 않았다.

```text
ssh -o BatchMode=yes -o ConnectTimeout=8 -o ControlPath=none jiun-home 'query session'
console  jiun  1  Active

python3 .tools/msstore/run-remote.py .tools/msstore/dpapi-diagnose-20261110.ps1
user=JIUN-HOME\jiun; profile=C:\Users\jiun; freshRoundtrip=false
CryptographicException: Access is denied. (0x80070005)

# 동일 user/session1의 native CryptProtectData 공개 fixture
flags=1 (CurrentUser/UI forbidden): success=false, win32Error=5
flags=0 (CurrentUser): success=false, win32Error=5
flags=5 (LocalMachine/public diagnostic only): success=true

# 동일 user/session1의 파일 핸들 검사(키 bytes 읽기/쓰기 없음)
8 master-key files + Preferred: readHandle=true, writeHandle=true

# 정상 Explorer와 검사 프로세스의 인증 컨텍스트 비교
probe.authId=2472047; explorer.authId=2472047; user/SID/session1 일치

python3 .tools/msstore/run-remote.py .tools/msstore/dpapi-owner-repair-20261110.ps1
ownerObjectsUpdated=4; daclBytesUnchanged=true
# 공개 roundtrip 계속 실패 → 시험한 owner 변경 모두 원복
python3 .tools/msstore/run-remote.py .tools/msstore/dpapi-owner-rollback-20261110.ps1
restoredObjects=4; originalSecurityDescriptorsRestored=true

# Crypto-DPAPI/Operational
8198: 0x8009000B / Could not get the master key
8203: Master Key decryption failed ... Diagnostic file

# 스냅샷 대조와 단일 키 복원
snapshot=2026-11-09 01:29 KST
same GUID/creation time/468 bytes; encrypted-file hashes differ
active key rewrite time=2026-11-09 20:38 KST
Copy-Item directly from VSS: failed (same NTFS file identity)
private staging → Copy-Item: encryptedKeysRestored=1, securityDescriptorUnchanged=true

# 복원 무결성
restoredFileMatchesSnapshot=true; originalBackupMatches=true
privateBackupAclProtected=true
publicFixtureVmkReferencesRestoredKey=true

# 복원 직후, 기존 대화형 세션의 새 프로세스
restored-probe-session1.json: roundtrip=false, Access is denied.
```

## 확인한 것과 아직 확인하지 못한 것

Windows는26H2/build26300.9818, KB5127936 적용 상태였다. 사용자 프로필은 loaded=true이고 SID/프로필 경로/필수 서비스가 일치했다. PowerShell task와 정상 Explorer는 **같은 인증 LUID**였다. .NET을 거치지 않은 native 사용자 DPAPI도 실패하고 공개 LocalMachine 대조만 성공했다. 제품은 계속 CurrentUser DPAPI를 사용하며 machine 보호로 바꾸지 않았다.

단순 파일 접근 및 사용자 소유권만의 문제라는 가설은 지지되지 않았다. 소유권 시험은 효과가 없어 모두 원복했다. System DLL 세 개의 Microsoft 서명은 Valid였고 ForceKeyProtection/FIPS 우회 설정은 하지 않았다. DPAPI Debug 채널을 짧게 켰다가 이전 disabled 상태로 복구했으나 공개 프로세스에 해당하는 event는0개였다. 이 빈 trace를 성공 증거로 취급하지 않는다.

기존 preferred master key와 공개 OTPeek fixture VMK가 참조하는 key GUID가 정확히 일치한다. 같은 GUID의 재기록 전 암호화 파일이 VSS 두 개에서 발견되어 최신 스냅샷의 **암호화 파일 한 개만** 복원했다. 다른 master key·Preferred 포인터·계정·비밀번호·PIN·사용자 vault는 변경하지 않았다. 원본 암호화 파일은 그대로 백업했고 owner/ACL도 유지했다. private backup은 `C:/Users/jiun/AppData/Local/OTPeek.DpapiRepair20261110`이며 jiun/SYSTEM/Administrators만 접근하도록 보호했다. 이 폴더의 암호화 키 파일은 Mac이나 Git으로 복사하지 않았다. 앱의 fixture 데이터와 이 복구 백업은 정리 대상으로 취급하지 않는다.

26H2에서 자동 로그인 후 master key 재기록과 같은 오류가 발생해 스냅샷 복원·정상 PIN 재로그인으로 복구한 **당사자 보고**가 있다. 현재 호스트와 유사한 증거이지만 OS 업데이트/자동 로그인 자체가 여기서도 정확한 원인이었다고 확정할 수는 없다. [Microsoft Q&A의 당사자 사례](https://learn.microsoft.com/en-us/answers/questions/6025889/after-windows-11-26h2-update-apps-lose-saved-login). Windows API의 사용자/컴퓨터 보호 범위는 [공식 CryptProtectData 설명](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)을 따른다.

**현재 상태는 복구 완료가 아니다.** 복원 직후 기존 로그온 세션에서는 공개 샘플이 계속 실패했다. 정상 PIN/비밀번호 재인증으로 현재 키 캐시를 갱신한 뒤 확인하는 단계가 남았다. 잠금/잠금 해제로 해결된다는 보장도 아직 없다. 사용자에게 작업 앱을 닫지 않는 잠금·정상 PIN/비밀번호 잠금 해제를 요청했고, 실제 인증 완료 응답을 기다린다. 응답 없이 로그오프·재부팅·암호/PIN 재설정을 실행하지 않는다.

## 대신 선택한 사항과 불확실성

- 기존 키와 GUID/생성시각이 일치하는 **최신 재기록 전** 스냅샷을 골랐다. 원본·스냅샷의 암호화 파일을 보호된 별도 폴더에 보존했다.
- 전체 profile/Protect 폴더 복원 대신 preferred key 한 개만 복원했다. ACL 확대나 암호화 우회는 적용하지 않았다.
- 현재 세션의 캐시/로그인 credential이 복원 키를 다시 열 수 있는지는 아직 검증되지 않았다. 다른 앱의 로그인 데이터가 복구됐다고 주장하지 않는다.
- 인증 뒤에도 실패하면 기존 파일과 snapshot 후보의 상태를 다시 대조하고, 현재 앱을 종료하는 복구 조치는 사용자와 조율한다.

## 다음 검증 순서

1. 정상 Windows PIN/비밀번호 인증 완료 후 새 일반 권한 프로세스의 CurrentUser 공개 DPAPI roundtrip을 확인한다.
2. 성공하면 새 격리 Windows 패키지의 공개 fixture UI·master 복구·계정 유지·재실행·런타임·주요 화면 검증을 진행한다.
3. 그 뒤 Partner Center 로그인 창을 열어 사용자에게 알린다. 인증 완료 후 실제 상품 identity와 최종 artifact를 대조하고 이미 승인된 제출을 이어간다.

현재 전체 UI·Store 제출은 미완료다. 과거 통과 검사를 반복하거나 권한 문제를 숨기는 제품 변경은 추가하지 않았다. 자세한 JSON/스크립트는 `.tools/msstore/evidence/` 및 원격 `evidence/dpapi-repair-20261110/`에 보존한다.
