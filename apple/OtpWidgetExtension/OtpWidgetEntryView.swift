import SwiftUI
import WidgetKit

/// 위젯 뷰
struct OtpWidgetEntryView: View {
    var entry: OtpEntry

    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        #if os(iOS)
        case .accessoryCircular:
            CircularAccessoryView(entry: entry)
        case .accessoryRectangular:
            RectangularAccessoryView(entry: entry)
        #endif
        default:
            SmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Small Widget

struct SmallWidgetView: View {
    let entry: OtpEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
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

            // Issuer
            Text(entry.displayIssuer)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            // Code
            Text(entry.displayCode)
                .privacySensitive()
                .font(.system(.title2, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(.primary)

            // Progress
            CountdownBar(window: entry.window)
                .tint(entry.isWarning ? .red : .blue)
        }
        .padding()
    }
}

// MARK: - Medium Widget

struct MediumWidgetView: View {
    let entry: OtpEntry

    var body: some View {
        HStack(spacing: 16) {
            // Left: Account Info
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

            // Right: Code
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
struct CircularAccessoryView: View {
    let entry: OtpEntry

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

struct RectangularAccessoryView: View {
    let entry: OtpEntry

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

// MARK: - Preview

#Preview(as: .systemSmall) {
    OtpWidget()
} timeline: {
    OtpEntry.placeholder
}

#Preview(as: .systemMedium) {
    OtpWidget()
} timeline: {
    OtpEntry.placeholder
}
