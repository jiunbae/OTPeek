import WidgetKit
import SwiftUI

@main
struct OtpWidgetBundle: WidgetBundle {
    var body: some Widget {
        // Default widget (shows first/favorite account)
        OtpWidget()

        // Configurable widget (user can select account)
        ConfigurableOtpWidget()

        // Multi-account list widget (tap a row to copy its code)
        MultiOtpWidget()
    }
}

struct OtpWidget: Widget {
    let kind: String = "OtpWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OtpTimelineProvider()) { entry in
            OtpWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("OTP Quick")
        .description("Display your favorite account's OTP code")
        .supportedFamilies(supportedFamilies)
    }

    private var supportedFamilies: [WidgetFamily] {
        #if os(iOS)
        return [.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular]
        #else
        return [.systemSmall, .systemMedium]
        #endif
    }
}
