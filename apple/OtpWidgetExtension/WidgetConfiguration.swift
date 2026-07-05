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
    let remainingSeconds: Int
    let progress: Double
    let configuration: SelectAccountIntent

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
            remainingSeconds: 30,
            progress: 1.0,
            configuration: SelectAccountIntent()
        )
    }

    func snapshot(for configuration: SelectAccountIntent, in context: Context) async -> ConfigurableOtpEntry {
        let account = getAccount(for: configuration)
        return createEntry(for: Date(), account: account, configuration: configuration)
    }

    func timeline(for configuration: SelectAccountIntent, in context: Context) async -> Timeline<ConfigurableOtpEntry> {
        var entries: [ConfigurableOtpEntry] = []
        let currentDate = Date()
        let account = getAccount(for: configuration)

        // Generate entries for the next 60 seconds
        for secondOffset in 0..<60 {
            let entryDate = currentDate.addingTimeInterval(Double(secondOffset))
            let entry = createEntry(for: entryDate, account: account, configuration: configuration)
            entries.append(entry)
        }

        let nextUpdate = currentDate.addingTimeInterval(60)
        return Timeline(entries: entries, policy: .after(nextUpdate))
    }

    private func getAccount(for configuration: SelectAccountIntent) -> OtpAccount? {
        guard let client = WidgetVault.openClient() else { return nil }
        if let accountEntity = configuration.account {
            return client.getAccount(id: accountEntity.id)
        }
        return WidgetVault.firstAccount(from: client)
    }

    private func createEntry(for date: Date, account: OtpAccount?, configuration: SelectAccountIntent) -> ConfigurableOtpEntry {
        if let account = account {
            let code = account.generateCode(at: date) ?? "------"
            let remainingSeconds = OtpGenerator.getRemainingSeconds(period: account.period, date: date)
            let progress = OtpGenerator.getProgress(period: account.period, date: date)

            return ConfigurableOtpEntry(
                date: date,
                account: account,
                code: code,
                remainingSeconds: remainingSeconds,
                progress: progress,
                configuration: configuration
            )
        } else {
            return ConfigurableOtpEntry(
                date: date,
                account: nil,
                code: "------",
                remainingSeconds: 30,
                progress: 1.0,
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
                InitialCircle(initial: entry.initial, color: entry.color, size: 32)

                Spacer()

                Text("\(entry.remainingSeconds)s")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(entry.remainingSeconds < 10 ? .red : .secondary)
            }

            Spacer()

            Text(entry.displayIssuer)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            Text(entry.displayCode)
                .font(.system(.title2, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(.primary)

            ProgressView(value: entry.progress)
                .tint(entry.remainingSeconds < 10 ? .red : .blue)
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
                InitialCircle(initial: entry.initial, color: entry.color, size: 44)

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
                Text("\(entry.remainingSeconds)s")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(entry.remainingSeconds < 10 ? .red : .secondary)

                Text(entry.displayCode)
                    .font(.system(.largeTitle, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(.primary)

                ProgressView(value: entry.progress)
                    .tint(entry.remainingSeconds < 10 ? .red : .blue)
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

                Text(entry.code.prefix(3))
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
            }
        }
    }
}

struct ConfigurableRectangularAccessoryView: View {
    let entry: ConfigurableOtpEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayIssuer)
                    .font(.caption)
                    .fontWeight(.medium)

                Text(entry.displayCode)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.bold)
            }

            Spacer()

            Gauge(value: entry.progress) {
                Text("\(entry.remainingSeconds)")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(entry.remainingSeconds < 10 ? .red : .blue)
        }
    }
}
#endif
