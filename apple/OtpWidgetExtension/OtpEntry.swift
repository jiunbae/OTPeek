import WidgetKit
import Foundation

/// 위젯 타임라인 엔트리
struct OtpEntry: TimelineEntry {
    let date: Date
    let account: OtpAccount?
    let code: String
    /// 현재 코드 구간. 카운트다운/진행 막대는 이 구간으로 시스템이 실시간으로 그린다.
    let window: ClosedRange<Date>
    /// 남은 시간이 경고 기준 미만인지(빨간색). 경고 진입 시각에 엔트리가 따로 있다.
    let isWarning: Bool
    /// 공유 캐시에서 읽은 파비콘/로고(있으면). 없으면 이니셜 원.
    var iconData: Data? = nil

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
            window: OtpTimeline.window(period: 30, at: Date()),
            isWarning: false
        )
    }

    /// 빈 엔트리
    static var empty: OtpEntry {
        OtpEntry(
            date: Date(),
            account: nil,
            code: "--- ---",
            window: OtpTimeline.window(period: 30, at: Date()),
            isWarning: false
        )
    }
}
