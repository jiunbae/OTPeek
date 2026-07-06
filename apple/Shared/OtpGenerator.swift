import Foundation

/// OTP 코드 생성 로직은 Rust 코어(otpeek-ffi)로 이전되었다.
/// 이 타입은 카운트다운/진행률 UI 계산을 위한 순수 시간 헬퍼만 남긴다.
/// (암호/HMAC/Base32 로직은 더 이상 여기에 없다.)
public enum OtpGenerator {

    /// 남은 시간 계산 (초)
    public static func getRemainingSeconds(period: UInt32 = 30, date: Date = Date()) -> Int {
        let p = Int(period == 0 ? 30 : period)
        let seconds = Int(date.timeIntervalSince1970)
        return p - (seconds % p)
    }

    /// 진행률 계산 (0.0 ~ 1.0)
    public static func getProgress(period: UInt32 = 30, date: Date = Date()) -> Double {
        let p = period == 0 ? 30 : period
        return Double(getRemainingSeconds(period: p, date: date)) / Double(p)
    }
}
