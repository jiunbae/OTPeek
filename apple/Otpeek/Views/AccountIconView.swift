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
        Group {
            if let image {
                // 로고가 있으면 깨끗한 흰 배경 위에만 그린다(뒤의 글자 원이 비치지 않게).
                // 하드 테두리 대신 아주 옅은 그림자로 분리감만 준다(사각형 로고에서
                // 로고 가장자리와 테두리가 이중으로 보이던 문제 제거).
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.12)
                    .frame(width: size, height: size)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 0.5, y: 0.5)
                    .transition(.opacity)
            } else {
                // 로고가 없을 때만 색상 이니셜 원.
                InitialCircle(initial: account.initial, color: account.displayColor, size: size)
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
