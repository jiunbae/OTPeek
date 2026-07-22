import Foundation
import StoreKit

/// StoreKit 2 기반 일회성 후원 매니저.
/// App Store Connect 의 기존 상품은 소모성이지만, 첫 구매 이후 모든 후원 상품을
/// 숨기고 거래 이력에서 구매 여부를 복원해 같은 사용자에게 다시 요청하지 않는다.
@MainActor
public final class StoreManager: ObservableObject {

    public static let tipIDs = [
        "com.otpeek.app.tip.espresso",
        "com.otpeek.app.tip.latte",
        "com.otpeek.app.tip.dessert",
    ]
    private static let hasSupportedKey = "hasSupportedOTPeek"

    /// 스토어에서 로드된 팁 상품(가격 오름차순).
    @Published public private(set) var tipProducts: [Product] = []

    /// 이 App Store 계정에서 한 번이라도 후원한 적이 있는지 여부.
    @Published public private(set) var hasSupported =
        UserDefaults.standard.bool(forKey: StoreManager.hasSupportedKey)

    /// 거래 이력 확인과 필요한 상품 로드가 끝나 UI를 표시해도 되는 상태.
    @Published public private(set) var isSupportStatusLoaded = false

    @Published public private(set) var isPurchasing = false

    private var updatesTask: Task<Void, Never>?

    public init() {
        // 앱 밖(승인 대기, 다른 기기 등)에서 완료된 트랜잭션도 즉시 반영한다.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task {
            await refreshSupportStatus()
            if !hasSupported {
                await loadProducts()
            }
            isSupportStatusLoaded = true
        }
    }

    deinit { updatesTask?.cancel() }

    public func loadProducts() async {
        guard !hasSupported else {
            tipProducts = []
            return
        }
        do {
            let products = try await Product.products(for: Self.tipIDs)
            tipProducts = products.sorted { $0.price < $1.price }
        } catch {
            // 네트워크/스토어 오류 — 버튼이 비활성으로 남을 뿐, 앱 동작엔 영향 없음.
        }
    }

    public func purchase(_ product: Product) async {
        guard !hasSupported, !isPurchasing, Self.tipIDs.contains(product.id) else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            if case .success(let verification) = result,
               case .verified(let transaction) = verification {
                markSupported()
                await transaction.finish()
            }
        } catch {
            // 결제 실패는 시스템 시트가 이미 사용자에게 보여준다.
        }
    }

    /// 재설치나 다른 기기에서도 기존 소모성 후원 거래를 찾아 구매 UI를 숨긴다.
    /// `SKIncludeConsumableInAppPurchaseHistory`가 두 앱 타깃의 Info.plist에 켜져 있다.
    public func refreshSupportStatus() async {
        guard !hasSupported else { return }

        for await result in Transaction.all {
            guard case .verified(let transaction) = result,
                  Self.tipIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            markSupported()
            return
        }
    }

    private func handle(_ update: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = update else { return }
        if Self.tipIDs.contains(transaction.productID), transaction.revocationDate == nil {
            markSupported()
        }
        await transaction.finish()
    }

    private func markSupported() {
        hasSupported = true
        tipProducts = []
        UserDefaults.standard.set(true, forKey: Self.hasSupportedKey)
    }
}
