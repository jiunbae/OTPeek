import Foundation
import StoreKit

/// StoreKit 2 기반 인앱결제 매니저.
/// - 팁(소모성 3종): 순수 후원. 아무 기능도 잠그지 않는다.
/// - 광고 제거(비소모성): iOS 배너 광고를 영구히 숨긴다(macOS 는 광고가 없음).
/// 영수증 검증은 StoreKit 2 의 `VerificationResult` 로 처리하고, 자격(entitlement)은
/// 실행 시마다 `Transaction.currentEntitlements` 로 재확인한다(UserDefaults 는 빠른 캐시).
@MainActor
public final class StoreManager: ObservableObject {

    public static let removeAdsID = "com.otpeek.app.removeads"
    public static let tipIDs = [
        "com.otpeek.app.tip.espresso",
        "com.otpeek.app.tip.latte",
        "com.otpeek.app.tip.dessert",
    ]
    private static let adsRemovedKey = "adsRemoved"

    /// 스토어에서 로드된 상품(가격 오름차순).
    @Published public private(set) var tipProducts: [Product] = []
    @Published public private(set) var removeAdsProduct: Product?

    /// 광고 제거 구매 여부(캐시 → 실행 중 entitlement 로 갱신).
    @Published public private(set) var adsRemoved =
        UserDefaults.standard.bool(forKey: StoreManager.adsRemovedKey)

    /// 방금 팁 결제가 완료됨(감사 메시지 표시용; 잠시 후 자동 해제).
    @Published public var showTipThanks = false

    @Published public private(set) var isPurchasing = false

    private var updatesTask: Task<Void, Never>?

    public init() {
        // 앱 밖(승인 대기, 다른 기기 환불 등)에서 발생한 트랜잭션 반영.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    deinit { updatesTask?.cancel() }

    public func loadProducts() async {
        do {
            let all = try await Product.products(for: Self.tipIDs + [Self.removeAdsID])
            tipProducts = all.filter { Self.tipIDs.contains($0.id) }.sorted { $0.price < $1.price }
            removeAdsProduct = all.first { $0.id == Self.removeAdsID }
        } catch {
            // 네트워크/스토어 오류 — 버튼이 비활성으로 남을 뿐, 앱 동작엔 영향 없음.
        }
    }

    public func purchase(_ product: Product) async {
        guard !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else { return }
                if transaction.productID == Self.removeAdsID {
                    setAdsRemoved(true)
                } else if Self.tipIDs.contains(transaction.productID) {
                    showTipThanks = true
                    Task { try? await Task.sleep(nanoseconds: 4_000_000_000)
                           await MainActor.run { self.showTipThanks = false } }
                }
                await transaction.finish()
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            // 결제 실패는 시스템 시트가 이미 사용자에게 보여준다.
        }
    }

    /// 재설치/기기 이전 후 "구매 복원".
    public func restorePurchases() async {
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    /// 현재 유효한 자격으로 광고 제거 여부를 재계산.
    public func refreshEntitlements() async {
        var owned = false
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let t) = entitlement, t.productID == Self.removeAdsID {
                owned = true
            }
        }
        setAdsRemoved(owned)
    }

    private func handle(_ update: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = update else { return }
        if transaction.productID == Self.removeAdsID {
            setAdsRemoved(transaction.revocationDate == nil)
        }
        await transaction.finish()
    }

    private func setAdsRemoved(_ value: Bool) {
        adsRemoved = value
        UserDefaults.standard.set(value, forKey: Self.adsRemovedKey)
    }
}
