import AppIntents
import WidgetKit
import SwiftUI

// MARK: - Account Entity

struct AccountEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "OTP Account")
    static var defaultQuery = AccountQuery()

    var id: String
    var issuer: String
    var accountName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(issuer.isEmpty ? accountName : issuer)",
            subtitle: issuer.isEmpty ? nil : "\(accountName)"
        )
    }

    init(from account: OtpAccount) {
        self.id = account.id
        self.issuer = account.issuerText
        self.accountName = account.accountName
    }

    init(id: String, issuer: String, accountName: String) {
        self.id = id
        self.issuer = issuer
        self.accountName = accountName
    }
}

// MARK: - Account Query

struct AccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AccountEntity] {
        let accounts = WidgetVault.openClient()?.listAccounts() ?? []
        return accounts
            .filter { identifiers.contains($0.id) }
            .map { AccountEntity(from: $0) }
    }

    func suggestedEntities() async throws -> [AccountEntity] {
        let accounts = WidgetVault.openClient()?.listAccounts() ?? []
        return accounts.map { AccountEntity(from: $0) }
    }

    func defaultResult() async -> AccountEntity? {
        guard let client = WidgetVault.openClient(),
              let account = WidgetVault.firstAccount(from: client) else {
            return nil
        }
        return AccountEntity(from: account)
    }
}

// MARK: - Widget Configuration Intent

struct SelectAccountIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select Account"
    static var description = IntentDescription("Choose which account to display in the widget")

    @Parameter(title: "Account")
    var account: AccountEntity?

    init() {}

    init(account: AccountEntity?) {
        self.account = account
    }
}

// MARK: - Configurable Widget

struct ConfigurableOtpWidget: Widget {
    let kind: String = "ConfigurableOtpWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectAccountIntent.self,
            provider: ConfigurableOtpTimelineProvider()
        ) { entry in
            ConfigurableOtpWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("OTP Code")
        .description("Display a specific account's OTP code")
        .supportedFamilies(supportedFamilies)
        .excludingIPhoneWidgetsOnMac(supportedFamilies)
    }

    private var supportedFamilies: [WidgetFamily] {
        #if os(iOS)
        return [
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular
        ]
        #else
        return [
            .systemSmall,
            .systemMedium
        ]
        #endif
    }
}

// MARK: - Configurable Timeline Entry

struct ConfigurableOtpEntry: TimelineEntry {
    let date: Date
    let account: OtpAccount?
    let code: String
    /// 현재 코드 구간(카운트다운/진행 막대용).
    let window: ClosedRange<Date>
    /// 남은 시간이 경고 기준 미만인지(빨간색).
    let isWarning: Bool
    let configuration: SelectAccountIntent
    /// 공유 캐시에서 읽은 파비콘/로고(있으면).
    var iconData: Data? = nil

    var displayIssuer: String {
        account?.issuerText ?? "No Account"
    }

    var displayAccountName: String {
        account?.accountName ?? "Select an account"
    }

    var displayCode: String {
        let formatted = code
        let mid = formatted.count / 2
        return String(formatted.prefix(mid)) + " " + String(formatted.suffix(formatted.count - mid))
    }

    var initial: String {
        account?.initial ?? "?"
    }

    var color: String {
        account?.displayColor ?? "#512BD4"
    }
}

// MARK: - Configurable Timeline Provider

struct ConfigurableOtpTimelineProvider: AppIntentTimelineProvider {
    typealias Entry = ConfigurableOtpEntry
    typealias Intent = SelectAccountIntent

    func placeholder(in context: Context) -> ConfigurableOtpEntry {
        ConfigurableOtpEntry(
            date: Date(),
            account: nil,
            code: "123456",
            window: OtpTimeline.window(period: 30, at: Date()),
            isWarning: false,
            configuration: SelectAccountIntent()
        )
    }

    func snapshot(for configuration: SelectAccountIntent, in context: Context) async -> ConfigurableOtpEntry {
        let account = getAccount(for: configuration)
        return createEntry(for: Date(), account: account, configuration: configuration)
    }

    func timeline(for configuration: SelectAccountIntent, in context: Context) async -> Timeline<ConfigurableOtpEntry> {
        guard let account = getAccount(for: configuration) else {
            let entry = createEntry(for: Date(), account: nil, configuration: configuration)
            return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(OtpTimeline.retryInterval)))
        }

        // 파비콘이 캐시에 없으면 받아 둔다(설정 on 일 때).
        await FaviconStore.shared.prefetch(account)
        let iconData = OtpTimeline.thumbnail(FaviconProvider.cachedData(for: account))

        // 코드가 바뀌는 순간/경고 진입 순간에만 엔트리를 두고, 다 쓰면 다시 받는다.
        let entries = OtpTimeline.entryDates(from: Date(), periods: [account.period]).map {
            createEntry(for: $0, account: account, configuration: configuration, iconData: iconData)
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    private func getAccount(for configuration: SelectAccountIntent) -> OtpAccount? {
        guard let client = WidgetVault.openClient() else { return nil }
        if let accountEntity = configuration.account {
            return client.getAccount(id: accountEntity.id)
        }
        return WidgetVault.firstAccount(from: client)
    }

    private func createEntry(for date: Date, account: OtpAccount?, configuration: SelectAccountIntent, iconData: Data? = nil) -> ConfigurableOtpEntry {
        if let account = account {
            return ConfigurableOtpEntry(
                date: date,
                account: account,
                code: account.generateCode(at: date) ?? "------",
                window: OtpTimeline.window(period: account.period, at: date),
                isWarning: OtpTimeline.isWarning(period: account.period, at: date),
                configuration: configuration,
                iconData: iconData
            )
        } else {
            return ConfigurableOtpEntry(
                date: date,
                account: nil,
                code: "------",
                window: OtpTimeline.window(period: 30, at: date),
                isWarning: false,
                configuration: configuration
            )
        }
    }
}

// MARK: - Configurable Widget Entry View

struct ConfigurableOtpWidgetEntryView: View {
    var entry: ConfigurableOtpEntry

    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            ConfigurableSmallWidgetView(entry: entry)
        case .systemMedium:
            ConfigurableMediumWidgetView(entry: entry)
        #if os(iOS)
        case .accessoryCircular:
            ConfigurableCircularAccessoryView(entry: entry)
        case .accessoryRectangular:
            ConfigurableRectangularAccessoryView(entry: entry)
        #endif
        default:
            ConfigurableSmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Small Widget View

struct ConfigurableSmallWidgetView: View {
    let entry: ConfigurableOtpEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                WidgetAccountIcon(iconData: entry.iconData, initial: entry.initial, color: entry.color, size: 32)

                Spacer()

                if entry.account != nil {
                    CountdownText(window: entry.window)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(entry.isWarning ? .red : .secondary)
                }
            }

            Spacer()

            Text(entry.displayIssuer)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            Text(entry.displayCode)
                .privacySensitive()
                .font(.system(.title2, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(.primary)

            CountdownBar(window: entry.window)
                .tint(entry.isWarning ? .red : .blue)
        }
        .padding()
    }
}

// MARK: - Medium Widget View

struct ConfigurableMediumWidgetView: View {
    let entry: ConfigurableOtpEntry

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                WidgetAccountIcon(iconData: entry.iconData, initial: entry.initial, color: entry.color, size: 44)

                Text(entry.displayIssuer)
                    .font(.headline)
                    .lineLimit(1)

                Text(entry.displayAccountName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                if entry.account != nil {
                    CountdownText(window: entry.window)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(entry.isWarning ? .red : .secondary)
                }

                Text(entry.displayCode)
                    .privacySensitive()
                    .font(.system(.largeTitle, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(.primary)

                CountdownBar(window: entry.window)
                    .tint(entry.isWarning ? .red : .blue)
                    .frame(width: 100)
            }
        }
        .padding()
    }
}

// MARK: - iOS Lock Screen Widgets

#if os(iOS)
struct ConfigurableCircularAccessoryView: View {
    let entry: ConfigurableOtpEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()

            VStack(spacing: 2) {
                Text(entry.initial)
                    .font(.caption)
                    .fontWeight(.bold)

                // 원형은 공간이 좁지만 앞 3자리만으로는 코드를 쓸 수 없으므로 6자리를 줄여서라도 다 보인다.
                Text(entry.code)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .privacySensitive()
            }
        }
    }
}

struct ConfigurableRectangularAccessoryView: View {
    let entry: ConfigurableOtpEntry

    var body: some View {
        // Gauge 는 엔트리마다만 값이 바뀌므로, 실시간으로 줄어드는 타이머 막대를 쓴다.
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(entry.displayIssuer)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if entry.account != nil {
                    CountdownText(window: entry.window, width: 44)
                        .font(.caption2)
                }
            }

            Text(entry.displayCode)
                .privacySensitive()
                .font(.system(.body, design: .monospaced))
                .fontWeight(.bold)

            CountdownBar(window: entry.window)
        }
    }
}
#endif
