import SwiftUI
#if canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#endif

/// Account avatar: shows the service's favicon when available, otherwise the
/// colored initial. Favicons are fetched once and cached on disk, so scrolling
/// and reopening are instant and offline-friendly.
struct AccountIconView: View {
    let account: OtpAccount
    var size: CGFloat = 34

    // App Group 저장소를 써서 위젯도 이 설정을 읽을 수 있게 한다.
    @AppStorage("showFavicons", store: UserDefaults.appGroup) private var showFavicons = true
    @State private var image: Image?

    var body: some View {
        ZStack {
            // Fallback / placeholder underneath keeps layout stable while loading.
            InitialCircle(initial: account.initial, color: account.displayColor, size: size)

            if let image {
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .task(id: taskKey) { await loadIcon() }
    }

    private var taskKey: String { "\(showFavicons)|\(FaviconProvider.domain(for: account) ?? "")" }

    private func loadIcon() async {
        guard showFavicons, let domain = FaviconProvider.domain(for: account) else {
            image = nil
            return
        }
        if let data = await FaviconStore.shared.iconData(for: domain),
           let platform = PlatformImage(data: data) {
            #if canImport(AppKit)
            let img = Image(nsImage: platform)
            #else
            let img = Image(uiImage: platform)
            #endif
            withAnimation(.easeIn(duration: 0.15)) { image = img }
        } else {
            image = nil
        }
    }
}
