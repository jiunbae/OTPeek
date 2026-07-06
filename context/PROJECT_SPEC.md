# Windows OTPeek - 프로젝트 기획서

## 1. 프로젝트 개요

### 1.1 프로젝트 명
**OTPeek for Windows**

### 1.2 목표
iOS의 OTP Auth 앱(https://apps.apple.com/kr/app/otpeek/id659877384)과 유사한 기능을 제공하는 Windows용 2단계 인증(2FA) 클라이언트 앱 개발

### 1.3 주요 특징
- 시스템 트레이 팝업으로 빠른 접근
- Windows 11 위젯 통합
- 클라우드 동기화 (OneDrive/Google Drive)
- Microsoft Store 배포

---

## 2. 기술 스택

| 항목 | 기술 | 버전 |
|------|------|------|
| 프레임워크 | WinUI 3 | 1.6+ |
| 런타임 | .NET | 8.0 |
| 언어 | C# | 12 |
| 아키텍처 패턴 | MVVM | - |
| 패키징 | MSIX | - |
| 최소 Windows 버전 | Windows 10 | 19041+ |

### 2.1 주요 NuGet 패키지

```xml
<!-- 핵심 -->
<PackageReference Include="Microsoft.WindowsAppSDK" Version="1.6.*" />
<PackageReference Include="CommunityToolkit.Mvvm" Version="8.3.*" />

<!-- 시스템 트레이 -->
<PackageReference Include="H.NotifyIcon.WinUI" Version="2.4.*" />

<!-- OTP 생성 -->
<PackageReference Include="Otp.NET" Version="1.4.*" />

<!-- QR 코드 -->
<PackageReference Include="ZXing.Net.Windows.Compatibility" Version="0.16.*" />

<!-- 클라우드 -->
<PackageReference Include="Microsoft.Graph" Version="5.*" />
<PackageReference Include="Google.Apis.Drive.v3" Version="1.*" />
```

---

## 3. 시스템 아키텍처

### 3.1 레이어 구조

```
┌─────────────────────────────────────────────────────────────┐
│                    Presentation Layer                        │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │   WinUI 3   │  │System Tray  │  │  Windows 11 Widget  │  │
│  │    Views    │  │   Popup     │  │     Provider        │  │
│  └──────┬──────┘  └──────┬──────┘  └──────────┬──────────┘  │
│         └────────────────┼───────────────────┘              │
│                          ▼                                   │
│  ┌───────────────────────────────────────────────────────┐  │
│  │              ViewModels (MVVM)                         │  │
│  └───────────────────────┬───────────────────────────────┘  │
├──────────────────────────┼──────────────────────────────────┤
│                          ▼       Business Layer              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                    Services                            │  │
│  │  OtpService │ BackupService │ CloudSyncService        │  │
│  │  QrCodeService │ ClipboardService │ SettingsService   │  │
│  └───────────────────────┬───────────────────────────────┘  │
├──────────────────────────┼──────────────────────────────────┤
│                          ▼       Data Layer                  │
│  ┌───────────────────────────────────────────────────────┐  │
│  │              SecureStorageService                      │  │
│  │  - PasswordVault (비밀 키)                             │  │
│  │  - DPAPI (로컬 데이터)                                 │  │
│  │  - AES-256 (백업 파일)                                 │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 프로젝트 구조

```
Otpeek/
├── Otpeek.sln
├── src/
│   ├── Otpeek.App/                # WinUI 3 메인 앱
│   │   ├── App.xaml / App.xaml.cs
│   │   ├── Package.appxmanifest
│   │   ├── Assets/
│   │   │   └── Logo/ (StoreLogo, TrayIcon 등)
│   │   ├── Views/
│   │   │   ├── MainWindow.xaml
│   │   │   ├── TrayPopupWindow.xaml
│   │   │   ├── AccountListView.xaml
│   │   │   ├── AccountEditView.xaml
│   │   │   ├── SettingsView.xaml
│   │   │   ├── QrScannerView.xaml
│   │   │   └── BackupRestoreView.xaml
│   │   ├── ViewModels/
│   │   │   ├── MainViewModel.cs
│   │   │   ├── TrayPopupViewModel.cs
│   │   │   ├── AccountListViewModel.cs
│   │   │   └── ...
│   │   ├── Controls/
│   │   │   ├── OtpCodeDisplay.xaml
│   │   │   └── CircularProgressTimer.xaml
│   │   ├── Converters/
│   │   └── Helpers/
│   │
│   ├── Otpeek.Core/               # 핵심 비즈니스 로직
│   │   ├── Models/
│   │   │   ├── OtpAccount.cs
│   │   │   ├── AppSettings.cs
│   │   │   └── BackupData.cs
│   │   ├── Services/
│   │   │   ├── Interfaces/
│   │   │   ├── OtpService.cs
│   │   │   ├── SecureStorageService.cs
│   │   │   ├── QrCodeService.cs
│   │   │   ├── BackupService.cs
│   │   │   ├── EncryptionService.cs
│   │   │   └── ClipboardService.cs
│   │   └── CloudSync/
│   │       ├── ICloudProvider.cs
│   │       ├── OneDriveProvider.cs
│   │       ├── GoogleDriveProvider.cs
│   │       └── SyncManager.cs
│   │
│   └── Otpeek.Widget/             # Windows 11 위젯
│       ├── WidgetProvider.cs
│       ├── OtpWidget.cs
│       └── Templates/
│           └── OtpWidgetTemplate.json
│
├── tests/
│   ├── Otpeek.Core.Tests/
│   └── Otpeek.App.Tests/
│
└── docs/
```

---

## 4. 데이터 모델

### 4.1 OTP 계정 (OtpAccount)

```csharp
public class OtpAccount
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Issuer { get; set; } = "";           // 발급자 (Google, GitHub 등)
    public string AccountName { get; set; } = "";      // 계정명 (email 등)
    public string SecretKey { get; set; } = "";        // Base32 인코딩된 비밀 키
    public OtpType Type { get; set; } = OtpType.TOTP;  // TOTP 또는 HOTP
    public HashAlgorithmType Algorithm { get; set; } = HashAlgorithmType.SHA1;
    public int Digits { get; set; } = 6;               // 코드 자릿수 (6 또는 8)
    public int Period { get; set; } = 30;              // TOTP 주기 (초)
    public long Counter { get; set; } = 0;             // HOTP 카운터
    public string? IconPath { get; set; }              // 아이콘 경로
    public string? Color { get; set; }                 // 테마 색상
    public int SortOrder { get; set; }                 // 정렬 순서
    public bool IsFavorite { get; set; }               // 즐겨찾기
    public DateTime CreatedAt { get; set; }
    public DateTime? LastUsedAt { get; set; }
}

public enum OtpType { TOTP, HOTP }
public enum HashAlgorithmType { SHA1, SHA256, SHA512 }
```

### 4.2 앱 설정 (AppSettings)

```csharp
public class AppSettings
{
    public bool StartWithWindows { get; set; } = false;
    public bool StartMinimized { get; set; } = true;
    public bool MinimizeToTray { get; set; } = true;
    public bool AutoCopyToClipboard { get; set; } = true;
    public int ClipboardClearSeconds { get; set; } = 30;
    public string Theme { get; set; } = "System";      // Light, Dark, System
    public bool EnableWidgetProvider { get; set; } = true;
    public CloudSyncSettings CloudSync { get; set; } = new();
}

public class CloudSyncSettings
{
    public bool Enabled { get; set; } = false;
    public CloudProvider Provider { get; set; } = CloudProvider.None;
    public bool AutoSync { get; set; } = true;
    public int SyncIntervalMinutes { get; set; } = 15;
}
```

### 4.3 백업 데이터 (BackupData)

```csharp
public class BackupData
{
    public string Version { get; set; } = "1.0";
    public DateTime CreatedAt { get; set; }
    public string DeviceName { get; set; }
    public List<OtpAccount> Accounts { get; set; } = new();
    public AppSettings? Settings { get; set; }
    public string Checksum { get; set; }  // SHA256 해시
}

public class EncryptedBackup
{
    public string Version { get; set; } = "1.0";
    public string Salt { get; set; }      // Base64 (32 bytes)
    public string IV { get; set; }        // Base64 (16 bytes)
    public string Data { get; set; }      // AES-256 암호화된 JSON (Base64)
    public string Hmac { get; set; }      // HMAC-SHA256 무결성 검증
}
```

---

## 5. 보안 설계

### 5.1 비밀 키 저장 (PasswordVault)

Windows Credential Manager를 사용하여 OTP 비밀 키 안전하게 저장

```csharp
// 저장
var credential = new PasswordCredential("Otpeek", accountId, secretKey);
vault.Add(credential);

// 조회
var credential = vault.Retrieve("Otpeek", accountId);
credential.RetrievePassword();
return credential.Password;
```

### 5.2 로컬 데이터 암호화 (DPAPI)

계정 메타데이터 등 로컬 파일을 DPAPI로 암호화

```csharp
// 암호화
byte[] encrypted = ProtectedData.Protect(
    data, null, DataProtectionScope.CurrentUser);

// 복호화
byte[] decrypted = ProtectedData.Unprotect(
    encrypted, null, DataProtectionScope.CurrentUser);
```

### 5.3 백업 파일 암호화 (AES-256)

| 항목 | 값 |
|------|-----|
| 알고리즘 | AES-256-CBC |
| 키 유도 | PBKDF2 (SHA256, 100,000 iterations) |
| Salt | 32 bytes (랜덤) |
| IV | 16 bytes (랜덤) |
| 무결성 | HMAC-SHA256 |

```csharp
public EncryptedBackup Encrypt(string plainText, string password)
{
    byte[] salt = RandomNumberGenerator.GetBytes(32);
    byte[] iv = RandomNumberGenerator.GetBytes(16);
    byte[] key = Rfc2898DeriveBytes.Pbkdf2(
        password, salt, 100000, HashAlgorithmName.SHA256, 32);

    using var aes = Aes.Create();
    aes.Key = key; aes.IV = iv;
    aes.Mode = CipherMode.CBC;
    aes.Padding = PaddingMode.PKCS7;

    // 암호화 및 HMAC 생성
    ...
}
```

### 5.4 클립보드 보안

- 자동 복사 후 설정된 시간(기본 30초) 후 클립보드 자동 삭제
- 클립보드 히스토리에서 제외 (SetClipboardData with CF_EXCLUDECLIPBOARDHISTORY)

---

## 6. 핵심 기능 상세

### 6.1 OTP 코드 생성

**TOTP (Time-based One-Time Password)**
- RFC 6238 표준
- 기본 30초 주기
- SHA1/SHA256/SHA512 알고리즘 지원

**HOTP (HMAC-based One-Time Password)**
- RFC 4226 표준
- 카운터 기반

```csharp
public string GenerateTotp(OtpAccount account)
{
    var totp = new Totp(
        Base32Encoding.ToBytes(account.SecretKey),
        step: account.Period,
        mode: GetOtpHashMode(account.Algorithm),
        totpSize: account.Digits);

    return totp.ComputeTotp();
}
```

### 6.2 QR 코드 스캔

**화면 캡처 방식**
1. `GraphicsCapturePicker`로 화면/창 선택
2. 캡처된 이미지에서 ZXing.NET으로 QR 코드 디코딩
3. `otpauth://` URI 파싱하여 계정 추가

**otpauth URI 형식**
```
otpauth://totp/Issuer:account@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Issuer&algorithm=SHA1&digits=6&period=30
```

### 6.3 시스템 트레이

**H.NotifyIcon.WinUI 사용**
- 좌클릭: 팝업 창 표시
- 더블클릭: 메인 창 열기
- 우클릭: 컨텍스트 메뉴

**팝업 창 특성**
- 프레임 없는 창 (borderless)
- Always on top
- 포커스 잃으면 자동 닫힘
- 작업 표시줄 근처에 위치

### 6.4 Windows 11 위젯

**Widget Provider 구현**
- `IWidgetProvider` 인터페이스 구현
- Adaptive Card JSON 템플릿 사용
- 즐겨찾기 계정의 OTP 코드 표시

**Package.appxmanifest 등록**
```xml
<uap3:Extension Category="windows.appExtension">
    <uap3:AppExtension Name="com.microsoft.windows.widgets"
                       Id="OtpWidget"
                       DisplayName="OTPeek">
        ...
    </uap3:AppExtension>
</uap3:Extension>
```

### 6.5 클라우드 동기화

**지원 플랫폼**
- OneDrive (Microsoft.Graph API)
- Google Drive (Google.Apis.Drive)

**동기화 전략**
- Last-write-wins (마지막 수정 시간 기준)
- 암호화된 백업 파일 형태로 동기화
- 충돌 시 사용자에게 선택권 부여

---

## 7. UI/UX 설계

### 7.1 시스템 트레이 팝업

```
┌──────────────────────────────┐
│ OTPeek    [설정] │
├──────────────────────────────┤
│ ┌──────────────────────────┐ │
│ │ [G] Google               │ │
│ │     user@gmail.com       │ │
│ │     123 456    [████░░]  │ │
│ └──────────────────────────┘ │
│ ┌──────────────────────────┐ │
│ │ [GH] GitHub              │ │
│ │     username             │ │
│ │     789 012    [███░░░]  │ │
│ └──────────────────────────┘ │
├──────────────────────────────┤
│   [QR 스캔]     [메인 창]   │
└──────────────────────────────┘
```

### 7.2 메인 창

- 계정 목록 (드래그 앤 드롭 정렬)
- 계정 추가/편집/삭제
- 검색 기능
- 설정 페이지
- 백업/복원 페이지

### 7.3 테마

- 시스템 테마 따르기 (기본)
- 라이트 모드
- 다크 모드
- Mica/Acrylic 배경 효과

---

## 8. 구현 우선순위

### Phase 1: 핵심 기능
1. 솔루션/프로젝트 구조 생성
2. DI 컨테이너 설정
3. OtpService (TOTP/HOTP 생성)
4. SecureStorageService (PasswordVault + DPAPI)
5. 기본 UI (계정 목록, 추가/편집)
6. 클립보드 자동 복사

### Phase 2: 트레이 & QR
7. 시스템 트레이 아이콘
8. 트레이 팝업 창
9. 화면 캡처 서비스
10. QR 코드 인식

### Phase 3: 백업 & 동기화
11. EncryptionService (AES-256)
12. BackupService
13. OneDrive 동기화
14. Google Drive 동기화

### Phase 4: 위젯 & 고급
15. Windows 11 Widget Provider
16. Windows Hello 통합 (선택)
17. 글로벌 핫키

### Phase 5: 배포
18. 다국어 지원 (ko-KR, en-US)
19. 접근성
20. Microsoft Store 제출

---

## 9. Microsoft Store 배포 체크리스트

- [ ] 앱 아이콘 (모든 크기)
- [ ] 스토어 스크린샷 (1920x1080, 4개 이상)
- [ ] 개인정보 처리방침 URL
- [ ] Windows App Certification Kit (WACK) 테스트 통과
- [ ] IARC 연령 등급 설정
- [ ] 앱 설명 (한국어, 영어)
- [ ] Partner Center 앱 예약 및 인증서

---

## 10. 참고 자료

- [WinUI 3 Gallery](https://github.com/microsoft/WinUI-Gallery)
- [H.NotifyIcon.WinUI](https://github.com/HavenDV/H.NotifyIcon)
- [Otp.NET](https://github.com/kspearrin/Otp.NET)
- [ZXing.Net](https://github.com/micjahn/ZXing.Net)
- [Windows Widget Provider](https://learn.microsoft.com/windows/apps/develop/widgets/widget-providers)
- [TOTP RFC 6238](https://tools.ietf.org/html/rfc6238)
- [HOTP RFC 4226](https://tools.ietf.org/html/rfc4226)
