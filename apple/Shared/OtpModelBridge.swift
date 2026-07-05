import Foundation

// 이 파일은 Rust 코어에서 생성된 UniFFI 타입(OtpAccount / OtpFolder / OtpType /
// HashAlgorithm / OtpCode)에 기존 SwiftUI 뷰가 기대하는 편의 API를 다시 붙여준다.
// 데이터 계층만 코어로 교체하고 UI/UX 는 그대로 유지하기 위한 호환 레이어다.

// MARK: - Enum raw values (UI 표시용)

extension OtpType {
    /// 기존 UI 가 사용하던 대문자 문자열 표현
    var rawValue: String { self == .totp ? "TOTP" : "HOTP" }
}

extension HashAlgorithm {
    var rawValue: String {
        switch self {
        case .sha1: return "SHA1"
        case .sha256: return "SHA256"
        case .sha512: return "SHA512"
        }
    }
}

// MARK: - Identifiable (ForEach / List 사용)

extension OtpAccount: Identifiable {}
extension OtpFolder: Identifiable {}

// MARK: - OtpAccount 편의 API

extension OtpAccount {
    /// 옵셔널 issuer 를 비-옵셔널 문자열로
    var issuerText: String { issuer ?? "" }

    /// 기존 코드가 사용하던 alias
    var type: OtpType { otpType }

    /// 표시 이름
    var displayName: String {
        if issuerText.isEmpty { return accountName }
        return "\(issuerText) (\(accountName))"
    }

    /// 아이콘용 이니셜
    var initial: String {
        let source = issuerText.isEmpty ? accountName : issuerText
        return String(source.prefix(1)).uppercased()
    }

    /// 비-옵셔널 색상 (기본값 포함)
    var displayColor: String { color ?? "#512BD4" }

    /// 기존 뷰/위젯 호환용 편의 이니셜라이저.
    /// id / createdAt / updatedAt 은 코어가 저장 시 채우므로 0/"" 로 둔다.
    init(
        issuer: String = "",
        accountName: String,
        secretKey: String,
        type: OtpType = .totp,
        algorithm: HashAlgorithm = .sha1,
        digits: Int = 6,
        period: Int = 30,
        counter: Int64 = 0,
        isFavorite: Bool = false,
        sortOrder: Int = 0,
        color: String = "#512BD4",
        folderId: String? = nil
    ) {
        let normalizedSecret = secretKey
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        self.init(
            id: "",
            otpType: type,
            secret: normalizedSecret,
            issuer: issuer.isEmpty ? nil : issuer,
            accountName: accountName,
            algorithm: algorithm,
            digits: UInt32(digits),
            period: UInt32(period),
            counter: UInt64(max(0, counter)),
            folderId: folderId,
            isFavorite: isFavorite,
            sortOrder: Int32(sortOrder),
            icon: nil,
            color: color,
            createdAt: 0,
            updatedAt: 0,
            deletedAt: nil
        )
    }

    /// 지정 시각의 TOTP 코드. 코어의 순수 함수(generateTotpNow)를 사용하므로
    /// 미리보기/위젯 프로세스에서도 비밀번호 없이 동작한다. HOTP 는 nil.
    func generateCode(at date: Date = Date()) -> String? {
        guard otpType == .totp else { return nil }
        let secs = Int64(date.timeIntervalSince1970)
        return try? generateTotpNow(
            secret: secret,
            algorithm: algorithm,
            digits: digits,
            period: period == 0 ? 30 : period,
            unixTimeSecs: secs
        )
    }
}

// MARK: - OtpFolder 편의 API

extension OtpFolder {
    var iconName: String { icon ?? "folder.fill" }
    var displayColor: String { color ?? "#007AFF" }

    /// 기존 뷰 호환용 편의 이니셜라이저 (id/createdAt/updatedAt 은 코어가 채움).
    init(
        name: String,
        icon: String = "folder.fill",
        color: String = "#007AFF",
        sortOrder: Int = 0
    ) {
        self.init(
            id: "",
            name: name,
            icon: icon,
            color: color,
            sortOrder: Int32(sortOrder),
            createdAt: 0,
            updatedAt: 0,
            deletedAt: nil
        )
    }
}
