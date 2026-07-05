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

                Text("\(entry.remainingSeconds)s")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(entry.remainingSeconds < 10 ? .red : .secondary)
            }

            Spacer()

            // Issuer
            Text(entry.displayIssuer)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            // Code
            Text(entry.displayCode)
                .font(.system(.title2, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(.primary)

            // Progress
            ProgressView(value: entry.progress)
                .tint(entry.remainingSeconds < 10 ? .red : .blue)
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
struct CircularAccessoryView: View {
    let entry: OtpEntry

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

struct RectangularAccessoryView: View {
    let entry: OtpEntry

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
