import WidgetKit
import SwiftUI
import AppIntents
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// 여러 계정의 코드를 한 위젯에 보여주고, 각 행을 눌러 바로 복사한다(iOS 17+ 인터랙티브 위젯).
// 코드 계산은 위젯 프로세스에서 Keychain VMK 로 볼트를 열어 비밀번호 없이 수행한다.

// MARK: - Copy feedback (위젯에 "복사됨" 표시)

/// 방금 복사한 행을 App Group 저장소에 기록한다. 인텐트 실행 후 타임라인이 리로드되면
/// 프로바이더가 이 값을 읽어 해당 행에 잠깐(약 2초) 체크마크를 보여준다.
enum CopyFeedback {
    /// 체크마크 표시 시간. 타임라인이 만들어진 시각부터 잰다. 시스템은 위젯 크기별 타임라인을
    /// 차례로 만든 뒤 한꺼번에 반영하므로(시뮬레이터에서 약 2초) 그만큼을 더 둔다.
    static let feedbackWindow: TimeInterval = 4.0
    /// 탭 후 이 시간 안에 만들어진 타임라인이면 "복사 직후" 리로드로 본다.
    static let pendingWindow: TimeInterval = 15
    /// 복사 직후 리로드는 빨리 끝나도록 엔트리를 이만큼만 만든다(다 쓰면 평소 리로드로 돌아간다).
    static let quickEntryCount = 8
    private static let idKey = "widget.lastCopiedId"
    private static let atKey = "widget.lastCopiedAt"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: VaultAccess.appGroupId) }

    static func record(_ id: String, at date: Date) {
        defaults?.set(id, forKey: idKey)
        defaults?.set(date.timeIntervalSince1970, forKey: atKey)
    }

    /// 마지막으로 복사한 계정 id 와 시각.
    static func recent() -> (id: String, at: Date)? {
        guard let d = defaults, let id = d.string(forKey: idKey) else { return nil }
        let at = Date(timeIntervalSince1970: d.double(forKey: atKey))
        return (id, at)
    }

    /// 체크마크가 사라지는 시각(위젯 크기별). 복사 후 그 크기의 첫 타임라인이 만들어질 때 정해지고,
    /// 같은 복사로 다시 만들어지는 타임라인(연달아 오는 리로드, 앱을 연 직후 리로드)은 그 시각을
    /// 그대로 쓴다. 그래서 체크마크가 다시 뜨거나 늘어나지 않고, 중간에 끊기지도 않는다.
    static func feedbackEnd(for family: String, copiedAt: Date, now: Date) -> Date {
        let copiedKey = "widget.copiedFor.\(family)", endKey = "widget.copiedUntil.\(family)"
        guard let d = defaults else { return now.addingTimeInterval(feedbackWindow) }
        if d.double(forKey: copiedKey) == copiedAt.timeIntervalSince1970 {
            return Date(timeIntervalSince1970: d.double(forKey: endKey))
        }
        let end = now.addingTimeInterval(feedbackWindow)
        d.set(copiedAt.timeIntervalSince1970, forKey: copiedKey)
        d.set(end.timeIntervalSince1970, forKey: endKey)
        return end
    }
}

// MARK: - Copy Intent (행 탭 → 클립보드 복사)

/// 행을 누르면 해당 계정의 현재 코드를 클립보드에 복사한다. 앱을 열지 않는다.
struct CopyCodeIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy OTP Code"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Account ID")
    var accountId: String

    init() {}
    init(accountId: String) { self.accountId = accountId }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let client = WidgetVault.openClient(),
           let account = client.getAccount(id: accountId),
           let code = account.generateCode() {
            #if os(iOS)
            UIPasteboard.general.string = code
            #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            #endif
            // "복사됨" 피드백 기록 후 위젯 새로고침 → 해당 행에 체크마크가 잠깐 뜬다.
            CopyFeedback.record(accountId, at: Date())
            WidgetCenter.shared.reloadTimelines(ofKind: "MultiOtpWidget")
        }
        return .result()
    }
}

// MARK: - Entry

struct MultiOtpEntry: TimelineEntry {
    let date: Date
    let items: [OtpRowItem]
    /// 방금 복사돼 체크마크를 보여줄 행(있으면). 피드백 창이 지나면 nil.
    var copiedId: String? = nil
}

struct OtpRowItem: Identifiable {
    let id: String
    let initial: String
    let color: String
    let issuer: String
    let accountName: String
    let code: String
    /// 현재 코드 구간(카운트다운용). 행마다 주기가 다를 수 있다.
    let window: ClosedRange<Date>
    /// 남은 시간이 경고 기준 미만인지(빨간색).
    let isWarning: Bool
    /// 공유 캐시에서 읽은 파비콘/로고(있으면). 없으면 이니셜 원을 그린다.
    var iconData: Data? = nil
}

// MARK: - Provider

struct MultiOtpTimelineProvider: TimelineProvider {
    /// 패밀리별로 보이는 행 수. 엔트리에는 보이는 계정만 담는다(안 보이는 행까지 담으면 엔트리가
    /// 커져 아카이브 한도에 빨리 닿는다).
    static func rowCount(for family: WidgetFamily) -> Int { family == .systemLarge ? 6 : 3 }

    func placeholder(in context: Context) -> MultiOtpEntry {
        MultiOtpEntry(date: Date(), items: MultiOtpTimelineProvider.sampleItems)
    }

    func getSnapshot(in context: Context, completion: @escaping (MultiOtpEntry) -> Void) {
        completion(makeEntry(for: Date(), accounts: loadAccounts(limit: Self.rowCount(for: context.family))))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MultiOtpEntry>) -> Void) {
        Task {
            let accounts = loadAccounts(limit: Self.rowCount(for: context.family))
            guard !accounts.isEmpty else {
                let entry = MultiOtpEntry(date: Date(), items: [])
                completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(OtpTimeline.retryInterval))))
                return
            }
            // 방금 행을 눌러 복사했다면 체크마크가 늦지 않게 이번 리로드를 가볍게 한다:
            // 파비콘은 캐시만 쓰고 엔트리도 몇 개만 만든다.
            let now = Date()
            let copied = CopyFeedback.recent().flatMap { c -> (id: String, until: Date)? in
                guard c.at <= now, now.timeIntervalSince(c.at) < CopyFeedback.pendingWindow else { return nil }
                let end = CopyFeedback.feedbackEnd(for: "\(context.family)", copiedAt: c.at, now: now)
                return end > now ? (c.id, end) : nil
            }

            // 아직 캐시에 없는 파비콘을 받아 공유 캐시에 채운다(설정이 켜져 있을 때만).
            if copied == nil { await prefetchFavicons(for: accounts) }
            let icons = faviconMap(for: accounts)

            // 모든 행의 코드 교체 순간에만 엔트리를 두고, 피드백 창이 끝나는 순간에도 하나 더 둬
            // 체크마크를 걷어낸다. 행이 많아 엔트리 하나가 크므로(행당 약 17KB) 아카이브 한도 안에
            // 들도록 경고색 엔트리는 생략하고 개수를 제한한다(30초 계정 기준 medium 40분, large 30분).
            let dates = OtpTimeline.entryDates(
                from: Date(),
                periods: accounts.map(\.period),
                warnings: false,
                maxCount: copied != nil ? CopyFeedback.quickEntryCount : (context.family == .systemLarge ? 60 : 80),
                extra: copied.map { [$0.until] } ?? []
            )
            let entries = dates.map { date -> MultiOtpEntry in
                let copiedId = copied.flatMap { date < $0.until ? $0.id : nil }
                return makeEntry(for: date, accounts: accounts, icons: icons, copiedId: copiedId)
            }
            completion(Timeline(entries: entries, policy: .after(OtpTimeline.reloadDate(after: dates, periods: accounts.map(\.period)))))
        }
    }

    // MARK: - Private

    /// 즐겨찾기 우선, 그다음 정렬 순서. 최대 limit 개.
    private func loadAccounts(limit: Int) -> [OtpAccount] {
        let all = WidgetVault.openClient()?.listAccounts() ?? []
        let favorites = all.filter { $0.isFavorite }
        let others = all.filter { !$0.isFavorite }
        return Array((favorites + others).prefix(limit))
    }

    /// 계정 id → 캐시된 파비콘 데이터. 설정이 꺼져 있으면 빈 맵.
    private func faviconMap(for accounts: [OtpAccount]) -> [String: Data] {
        guard FaviconProvider.faviconsEnabled else { return [:] }
        var map: [String: Data] = [:]
        for a in accounts {
            if let dom = FaviconProvider.domain(for: a), let data = FaviconProvider.cachedData(for: dom) {
                map[a.id] = OtpTimeline.thumbnail(data)
            }
        }
        return map
    }

    /// 캐시에 없는 파비콘만 동시 다운로드(위젯이 스스로 채운다).
    private func prefetchFavicons(for accounts: [OtpAccount]) async {
        guard FaviconProvider.faviconsEnabled else { return }
        await withTaskGroup(of: Void.self) { group in
            for a in accounts {
                guard let dom = FaviconProvider.domain(for: a),
                      FaviconProvider.cachedData(for: dom) == nil else { continue }
                group.addTask { _ = await FaviconStore.shared.iconData(for: dom) }
            }
        }
    }

    private func makeEntry(for date: Date, accounts: [OtpAccount], icons: [String: Data] = [:], copiedId: String? = nil) -> MultiOtpEntry {
        let items = accounts.map { account -> OtpRowItem in
            OtpRowItem(
                id: account.id,
                initial: account.initial,
                color: account.displayColor,
                issuer: account.issuerText.isEmpty ? account.accountName : account.issuerText,
                accountName: account.accountName,
                code: account.generateCode(at: date) ?? "------",
                window: OtpTimeline.window(period: account.period, at: date),
                isWarning: OtpTimeline.isWarning(period: account.period, at: date),
                iconData: icons[account.id]
            )
        }
        return MultiOtpEntry(date: date, items: items, copiedId: copiedId)
    }

    static var sampleItems: [OtpRowItem] {
        let sampleWindow = OtpTimeline.window(period: 30, at: Date())
        return [
            OtpRowItem(id: "1", initial: "G", color: "#4285F4", issuer: "Google", accountName: "me@gmail.com", code: "123456", window: sampleWindow, isWarning: false),
            OtpRowItem(id: "2", initial: "A", color: "#FF9500", issuer: "Amazon", accountName: "me@me.com", code: "482915", window: sampleWindow, isWarning: false),
            OtpRowItem(id: "3", initial: "G", color: "#24292E", issuer: "GitHub", accountName: "octocat", code: "705513", window: sampleWindow, isWarning: false),
        ]
    }
}

// MARK: - Widget

struct MultiOtpWidget: Widget {
    let kind: String = "MultiOtpWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MultiOtpTimelineProvider()) { entry in
            MultiOtpWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("OTP List")
        .description("Show several accounts. Tap a code to copy it.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .excludingIPhoneWidgetsOnMac([.systemMedium, .systemLarge])
    }
}

// MARK: - Entry View

struct MultiOtpWidgetEntryView: View {
    var entry: MultiOtpEntry
    @Environment(\.widgetFamily) var family

    /// 패밀리별 표시 행 수(타임라인이 담는 계정 수와 같다).
    private var rowCount: Int { MultiOtpTimelineProvider.rowCount(for: family) }

    var body: some View {
        if entry.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No accounts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(entry.items.prefix(rowCount).enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    OtpWidgetRow(item: item, copied: entry.copiedId == item.id)
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }
}

// MARK: - Account icon (favicon or initial)

/// 캐시된 파비콘/로고가 있으면 보여주고, 없으면 색상 이니셜 원을 그린다.
/// 모든 위젯(단일/설정형/리스트)이 공유한다.
struct WidgetAccountIcon: View {
    let iconData: Data?
    let initial: String
    let color: String
    var size: CGFloat = 26

    var body: some View {
        if let data = iconData, let image = Self.image(from: data) {
            // 앱과 동일하게 깨끗한 흰 배경 위에 로고만(투명 로고가 위젯 배경에 얹혀 지저분해지지 않게).
            // 앱(AccountIconView)과 같은 패딩/코너/그림자로 디자인 언어를 일치시킨다.
            image
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(size * 0.12)
                .frame(width: size, height: size)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 0.5, y: 0.5)
        } else {
            InitialCircle(initial: initial, color: color, size: size)
        }
    }

    private static func image(from data: Data) -> Image? {
        #if os(iOS)
        return UIImage(data: data).map(Image.init(uiImage:))
        #elseif os(macOS)
        return NSImage(data: data).map(Image.init(nsImage:))
        #else
        return nil
        #endif
    }
}

// MARK: - Row (tap to copy)

struct OtpWidgetRow: View {
    let item: OtpRowItem
    var copied: Bool = false

    var body: some View {
        Button(intent: CopyCodeIntent(accountId: item.id)) {
            HStack(spacing: 10) {
                WidgetAccountIcon(iconData: item.iconData, initial: item.initial, color: item.color, size: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.issuer)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(item.accountName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if copied {
                    // 복사 직후 피드백(약 2초). 코드 대신 "Copied" 표시.
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formatOtpCode(item.code))
                            .privacySensitive()
                            .font(.system(.callout, design: .monospaced))
                            .fontWeight(.bold)
                            .monospacedDigit()
                            .lineLimit(1)
                            .foregroundColor(item.isWarning ? .red : .primary)
                        CountdownText(window: item.window, width: 40)
                            .font(.system(size: 9))
                            .foregroundColor(item.isWarning ? .red : .secondary)
                    }
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
