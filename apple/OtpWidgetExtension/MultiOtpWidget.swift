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
    static let feedbackWindow: TimeInterval = 2.0
    private static let idKey = "widget.lastCopiedId"
    private static let atKey = "widget.lastCopiedAt"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: VaultAccess.appGroupId) }

    static func record(_ id: String, at date: Date) {
        defaults?.set(id, forKey: idKey)
        defaults?.set(date.timeIntervalSince1970, forKey: atKey)
    }

    /// 피드백 창(feedbackWindow) 안이라면 방금 복사한 계정 id, 아니면 nil.
    static func recent() -> (id: String, at: Date)? {
        guard let d = defaults, let id = d.string(forKey: idKey) else { return nil }
        let at = Date(timeIntervalSince1970: d.double(forKey: atKey))
        return (id, at)
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
    let remaining: Int
    let progress: Double
    /// 공유 캐시에서 읽은 파비콘/로고(있으면). 없으면 이니셜 원을 그린다.
    var iconData: Data? = nil
}

// MARK: - Provider

struct MultiOtpTimelineProvider: TimelineProvider {
    /// 위젯에 담을 최대 계정 수(가장 큰 패밀리 기준). 뷰가 패밀리별로 잘라서 표시한다.
    private let maxAccounts = 6

    func placeholder(in context: Context) -> MultiOtpEntry {
        MultiOtpEntry(date: Date(), items: MultiOtpTimelineProvider.sampleItems)
    }

    func getSnapshot(in context: Context, completion: @escaping (MultiOtpEntry) -> Void) {
        completion(makeEntry(for: Date(), accounts: loadAccounts()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MultiOtpEntry>) -> Void) {
        Task {
            let accounts = loadAccounts()
            guard !accounts.isEmpty else {
                let entry = MultiOtpEntry(date: Date(), items: [])
                completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(300))))
                return
            }
            // 아직 캐시에 없는 파비콘을 받아 공유 캐시에 채운다(설정이 켜져 있을 때만).
            await prefetchFavicons(for: accounts)
            let icons = faviconMap(for: accounts)

            var entries: [MultiOtpEntry] = []
            let now = Date()
            let copied = CopyFeedback.recent()
            for offset in 0..<60 {
                let date = now.addingTimeInterval(Double(offset))
                // 방금 복사한 행이면 피드백 창 동안만 체크마크를 표시한다.
                var copiedId: String? = nil
                if let c = copied {
                    let dt = date.timeIntervalSince(c.at)
                    if dt >= 0 && dt < CopyFeedback.feedbackWindow { copiedId = c.id }
                }
                entries.append(makeEntry(for: date, accounts: accounts, icons: icons, copiedId: copiedId))
            }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(60))))
        }
    }

    // MARK: - Private

    /// 즐겨찾기 우선, 그다음 정렬 순서. 최대 maxAccounts 개.
    private func loadAccounts() -> [OtpAccount] {
        let all = WidgetVault.openClient()?.listAccounts() ?? []
        let favorites = all.filter { $0.isFavorite }
        let others = all.filter { !$0.isFavorite }
        return Array((favorites + others).prefix(maxAccounts))
    }

    /// 계정 id → 캐시된 파비콘 데이터. 설정이 꺼져 있으면 빈 맵.
    private func faviconMap(for accounts: [OtpAccount]) -> [String: Data] {
        guard FaviconProvider.faviconsEnabled else { return [:] }
        var map: [String: Data] = [:]
        for a in accounts {
            if let dom = FaviconProvider.domain(for: a), let data = FaviconProvider.cachedData(for: dom) {
                map[a.id] = data
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
                remaining: OtpGenerator.getRemainingSeconds(period: account.period, date: date),
                progress: OtpGenerator.getProgress(period: account.period, date: date),
                iconData: icons[account.id]
            )
        }
        return MultiOtpEntry(date: date, items: items, copiedId: copiedId)
    }

    static var sampleItems: [OtpRowItem] {
        [
            OtpRowItem(id: "1", initial: "G", color: "#4285F4", issuer: "Google", accountName: "me@gmail.com", code: "123456", remaining: 21, progress: 0.7),
            OtpRowItem(id: "2", initial: "A", color: "#FF9500", issuer: "Amazon", accountName: "me@me.com", code: "482915", remaining: 21, progress: 0.7),
            OtpRowItem(id: "3", initial: "G", color: "#24292E", issuer: "GitHub", accountName: "octocat", code: "705513", remaining: 21, progress: 0.7),
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
    }
}

// MARK: - Entry View

struct MultiOtpWidgetEntryView: View {
    var entry: MultiOtpEntry
    @Environment(\.widgetFamily) var family

    /// 패밀리별 표시 행 수.
    private var rowCount: Int {
        switch family {
        case .systemLarge: return 6
        default: return 3   // systemMedium
        }
    }

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
            image
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
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
                            .font(.system(.callout, design: .monospaced))
                            .fontWeight(.bold)
                            .monospacedDigit()
                            .lineLimit(1)
                            .foregroundColor(item.remaining < 10 ? .red : .primary)
                        Text("\(item.remaining)s")
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundColor(item.remaining < 10 ? .red : .secondary)
                    }
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
