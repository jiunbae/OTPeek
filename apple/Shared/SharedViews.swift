import SwiftUI

// MARK: - Initial Circle

struct InitialCircle: View {
    let initial: String
    let color: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: color) ?? .blue)
                .frame(width: size, height: size)

            Text(initial)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

// MARK: - Time-driven OTP tick

/// Drives OTP code + countdown redraws efficiently.
///
/// Only the wrapped `content` is re-evaluated — once per second, aligned to the
/// wall clock — instead of invalidating the whole view/store graph. `TimelineView`
/// also stops firing when the view is offscreen (lazy rows) or the app/menu is
/// inactive, so idle CPU stays near zero no matter how many accounts exist.
///
/// `code` must be a *read-only* provider for a given instant (TOTP compute or
/// HOTP peek) so re-rendering never mutates state.
struct OTPTick<Content: View>: View {
    let account: OtpAccount
    let code: (Date) -> String
    @ViewBuilder let content: (_ code: String, _ remaining: Int, _ progress: Double) -> Content

    var body: some View {
        // `from` epoch 0 keeps ticks aligned to whole-second boundaries.
        TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 1)) { context in
            let now = context.date
            content(
                code(now),
                OtpGenerator.getRemainingSeconds(period: account.period, date: now),
                OtpGenerator.getProgress(period: account.period, date: now)
            )
        }
    }
}

/// Splits a raw code into two halves for readability ("123 456").
func formatOtpCode(_ code: String) -> String {
    let mid = code.count / 2
    guard mid > 0 else { return code }
    return String(code.prefix(mid)) + " " + String(code.suffix(code.count - mid))
}

// MARK: - Countdown ring

/// Compact circular countdown with the remaining seconds in the middle.
/// Shared by the account list and the menu bar so timing reads consistently.
struct CountdownRing: View {
    let progress: Double
    let remaining: Int
    let urgent: Bool
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(urgent ? Color.red : Color.accentColor,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(remaining)")
                .font(.system(size: size * 0.42, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(urgent ? .red : .secondary)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Color Extension

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }

        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }

    static var cardBackground: Color {
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(uiColor: .systemBackground)
        #endif
    }
}

// MARK: - Preview

#Preview {
    HStack(spacing: 16) {
        InitialCircle(initial: "G", color: "#4285F4", size: 48)
        InitialCircle(initial: "A", color: "#EA4335", size: 48)
        InitialCircle(initial: "M", color: "#34A853", size: 48)
    }
    .padding()
}
