#if os(iOS)
import SwiftUI
import UIKit
#if canImport(GoogleMobileAds)
import GoogleMobileAds

/// 리스트 하단에 붙는 AdMob 적응형 배너(iOS 전용, 광고 제거 미구매 시에만 표시).
/// ATT 를 요청하지 않으므로 비개인화 광고로만 서빙된다(개인정보 라벨 최소화).
struct AdBannerView: UIViewRepresentable {
    /// AdMob 배너 광고 단위 ID. 실제 단위 발급 전까지는 Google 공식 테스트 ID.
    static let adUnitID = "ca-app-pub-3940256099942544/2934735716"  // TODO: 실제 ID 로 교체

    func makeUIView(context: Context) -> BannerView {
        let width = UIScreen.main.bounds.width
        let banner = BannerView(adSize: currentOrientationAnchoredAdaptiveBanner(width: width))
        banner.adUnitID = Self.adUnitID
        banner.rootViewController = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first
        let request = Request()
        // ATT 미요청 → 비개인화 광고 명시.
        let extras = Extras()
        extras.additionalParameters = ["npa": "1"]
        request.register(extras)
        banner.load(request)
        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {}
}

enum AdSetup {
    /// 앱 시작 시 1회 호출. 광고 제거 구매자는 SDK 초기화 자체를 건너뛴다.
    static func startIfNeeded(adsRemoved: Bool) {
        guard !adsRemoved else { return }
        MobileAds.shared.start()
    }
}
#else
/// GoogleMobileAds 패키지가 없는 구성(예: 위젯/테스트)에서의 무해한 폴백.
struct AdBannerView: View { var body: some View { EmptyView() } }
enum AdSetup { static func startIfNeeded(adsRemoved: Bool) {} }
#endif
#endif
