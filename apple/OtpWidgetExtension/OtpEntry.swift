import WidgetKit
import Foundation

/// 위젯 타임라인 엔트리
struct OtpEntry: TimelineEntry {
    let date: Date
    let account: OtpAccount?
    let code: String
    let progress: Double
    let remainingSeconds: Int

    var hasAccount: Bool {
        return account != nil
    }

    var displayIssuer: String {
        return account?.issuerText ?? "No Account"
    }

    var displayAccountName: String {
        return account?.accountName ?? "Add an account"
    }

    var displayCode: String {
        return formatCode(code)
    }

    var initial: String {
        return account?.initial ?? "?"
    }

    var color: String {
        return account?.displayColor ?? "#512BD4"
    }

    /// 코드 포맷팅 (3자리씩 공백 구분)
    private func formatCode(_ code: String) -> String {
        guard code.count >= 6 else { return code }

        let midIndex = code.index(code.startIndex, offsetBy: code.count / 2)
        let firstPart = code[..<midIndex]
        let secondPart = code[midIndex...]

        return "\(firstPart) \(secondPart)"
    }

    /// 샘플 엔트리 (미리보기용)
    static var placeholder: OtpEntry {
        OtpEntry(
            date: Date(),
            account: OtpAccount(
                issuer: "Google",
                accountName: "user@gmail.com",
                secretKey: "JBSWY3DPEHPK3PXP"
            ),
            code: "123 456",
            progress: 0.7,
            remainingSeconds: 21
        )
    }

    /// 빈 엔트리
    static var empty: OtpEntry {
        OtpEntry(
            date: Date(),
            account: nil,
            code: "--- ---",
            progress: 1.0,
            remainingSeconds: 30
        )
    }
}
