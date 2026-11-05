import SwiftUI
import WidgetKit

/// 위젯 타임라인 계산 헬퍼 (모든 OTP 위젯 공용).
///
/// WidgetKit 은 위젯당 하루 리로드 횟수(약 40~70회)를 제한한다. 1초마다 엔트리를 만들고 60초마다
/// 리로드를 요청하면 예산이 금방 바닥나고, 그 뒤로는 마지막 엔트리(이미 만료된 코드)에서 위젯이 멈춘다.
/// TOTP 는 시각만으로 결정되므로 화면이 실제로 바뀌는 순간(코드 교체, 경고색 진입)에만 엔트리를 두고,
/// 카운트다운/진행 막대는 `Text(timerInterval:)`·`ProgressView(timerInterval:)` 로 시스템이 실시간으로 그린다.
enum OtpTimeline {
    /// 한 번의 리로드로 미리 계산해 두는 기간. 시간당 1회 리로드면 예산 안에 넉넉히 든다.
    static let horizon: TimeInterval = 60 * 60
    /// 남은 시간이 이 값 미만이면 빨간색 경고.
    static let warningSeconds = 10
    /// 단일 계정 위젯의 엔트리 상한. 30초 주기면 1시간치(241개)이고, 15초처럼 짧은 주기에서
    /// 아카이브가 한없이 커지지 않게 막는다.
    static let singleMaxEntries = 241
    /// 볼트를 열 수 없을 때(재부팅 후 첫 잠금 해제 전 등) 다시 시도할 간격.
    static let retryInterval: TimeInterval = 5 * 60

    fileprivate static func normalized(_ period: UInt32) -> Int { Int(period == 0 ? 30 : period) }

    /// date 가 속한 코드 구간(시작 ~ 다음 코드로 바뀌는 시각).
    static func window(period: UInt32, at date: Date) -> ClosedRange<Date> {
        let p = normalized(period)
        let secs = Int(date.timeIntervalSince1970)
        let start = secs - secs % p
        return Date(timeIntervalSince1970: TimeInterval(start))...Date(timeIntervalSince1970: TimeInterval(start + p))
    }

    static func isWarning(period: UInt32, at date: Date) -> Bool {
        OtpGenerator.getRemainingSeconds(period: period, date: date) < warningSeconds
    }

    /// now 부터 horizon 까지 화면이 바뀌는 시각들(now 포함, 초 단위로 정렬·중복 제거).
    /// - warnings: 경고색 진입 시각에도 엔트리를 둘지. 끄면 엔트리가 절반이 된다.
    /// - maxCount: 엔트리 수 상한. 시스템은 타임라인 아카이브가 너무 크면(약 11MB) 통째로 거부하고
    ///   한 시간 뒤에야 다시 시도하므로, 행이 많은 위젯은 엔트리 수를 줄여야 한다.
    /// - extra: 그 밖에 엔트리가 필요한 시각(예: "Copied" 표시가 사라지는 순간).
    static func entryDates(from now: Date, periods: [UInt32], warnings: Bool = true, maxCount: Int = .max, extra: [Date] = []) -> [Date] {
        let start = Int(now.timeIntervalSince1970)
        let end = start + Int(horizon)
        var secs: Set<Int> = [start]
        for p in Set(periods.map(normalized)) {
            // 남은 시간이 warningSeconds 미만이 되는 첫 초(경계 기준 오프셋).
            let warningOffset = p - warningSeconds + 1
            var boundary = start - start % p
            while boundary <= end {
                secs.insert(boundary)
                if warnings && warningOffset > 0 { secs.insert(boundary + warningOffset) }
                boundary += p
            }
        }
        for d in extra { secs.insert(Int(d.timeIntervalSince1970.rounded(.up))) }
        var dates = secs.filter { $0 >= start && $0 <= end }
        // 주기가 horizon 보다 길어 그 안에 경계가 없으면, 다음 경계에도 엔트리를 하나 둔다.
        // 리로드가 늦게 돌아도 그 사이 만료된 코드를 보이지 않게 한다.
        for p in Set(periods.map(normalized)) where p > Int(horizon) { dates.insert(start - start % p + p) }
        return dates.sorted().prefix(maxCount).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

// MARK: - iPhone widgets on Mac

extension WidgetConfiguration {
    /// iPhone 위젯을 Mac 데스크톱에 띄우는 원격 위젯에서 뺀다. 원격 위젯은 iPhone 이 만든
    /// 타임라인을 Mac 으로 보내야 하는데, 30초마다 바뀌는 코드를 담은 타임라인은 너무 커서
    /// 한 번도 전달되지 않고(Mac 에는 회색 자리표시만 남음) 코드가 다른 기기로 넘어가는 것도
    /// 바람직하지 않다. Mac 에서는 Mac 앱의 위젯을 쓴다.
    func excludingIPhoneWidgetsOnMac(_ families: [WidgetFamily]) -> some WidgetConfiguration {
        #if os(iOS)
        return disfavoredLocations([.iPhoneWidgetsOnMac], for: families)
        #else
        return self
        #endif
    }
}

extension OtpTimeline {
    /// 엔트리를 다 쓴 뒤 다시 불러올 시각. 보통은 마지막 엔트리 시각(.atEnd 와 같음)이지만,
    /// 주기가 horizon 보다 길어 엔트리가 거의 없으면 다음 코드 경계까지 기다린다. 그러지 않으면
    /// 마지막 엔트리가 곧 지금이라 곧바로 다시 불러오기를 반복한다.
    static func reloadDate(after dates: [Date], periods: [UInt32]) -> Date {
        let start = Int((dates.first ?? Date()).timeIntervalSince1970)
        let nextBoundary = periods.map { p -> Int in
            let p = normalized(p)
            return start - start % p + p
        }.min() ?? start + 30
        return max(dates.last ?? Date(), Date(timeIntervalSince1970: TimeInterval(nextBoundary)))
    }
}

// MARK: - Icon thumbnail

extension OtpTimeline {
    /// 위젯 아이콘용 썸네일(최대 maxPixel px PNG). 엔트리마다 아이콘이 아카이브되므로 큰 이미지는
    /// 이미지 면적 한도(imageTooLarge)에 걸려 타임라인 저장이 통째로 실패한다(iPhone 에서 확인).
    static func thumbnail(_ data: Data?, maxPixel: Int = 96) -> Data? {
        FaviconProvider.downscaled(data, maxPixel: maxPixel)
    }
}

// MARK: - Live countdown views

/// 남은 시간 카운트다운("0:21"). 엔트리 없이 시스템이 매초 갱신한다.
/// 타이머 Text 는 가로로 최대한 늘어나려 하므로 폭을 고정해 레이아웃을 지킨다.
struct CountdownText: View {
    let window: ClosedRange<Date>
    var width: CGFloat = 48
    /// 상시 표시(AOD)·StandBy 야간처럼 화면이 어두워진 상태. 이때는 매초 다시 그리지 않도록
    /// 카운트다운을 숨긴다(코드는 엔트리로 계속 바뀐다).
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        (isLuminanceReduced ? AnyView(Text(" ")) : AnyView(timer))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .multilineTextAlignment(.trailing)
            .frame(width: width, alignment: .trailing)
    }

    /// 표시용 타이머 구간. 60초 이상 구간이면 시스템 타이머가 남은 57초를 "1:57" 처럼 분을
    /// 올려 그리므로(iOS 시뮬레이터에서 확인) 끝 시각은 그대로 두고 길이만 59초 이하로 줄인다.
    private var timerRange: ClosedRange<Date> {
        max(window.lowerBound, window.upperBound.addingTimeInterval(-59))...window.upperBound
    }

    private var timer: some View {
        Text(timerInterval: timerRange, countsDown: true)
    }
}

/// 코드 구간 동안 줄어드는 진행 막대. 시스템이 실시간으로 애니메이션한다.
struct CountdownBar: View {
    let window: ClosedRange<Date>
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        // 어두운 상태에서는 매초 움직이는 막대 대신 빈 자리만 둔다(레이아웃 유지).
        if isLuminanceReduced {
            Color.clear.frame(height: 4)
        } else {
            ProgressView(timerInterval: window, countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
        }
    }
}
