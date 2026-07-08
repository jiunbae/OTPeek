import Foundation
import StoreKit

/// StoreKit 2 기반 인앱결제 매니저(v1.0 = 팁 전용).
/// 팁 3종(소모성)은 순수 후원으로, 어떤 기능도 잠그거나 해제하지 않는다.
/// 영수증 검증은 StoreKit 2 의 `VerificationResult` 로 처리한다.
@MainActor
public final class StoreManager: ObservableObject {

    public static let tipIDs = [
        "com.otpeek.app.tip.espresso",
        "com.otpeek.app.tip.latte",
        "com.otpeek.app.tip.dessert",
    ]

    /// 스토어에서 로드된 팁 상품(가격 오름차순).
    @Published public private(set) var tipProducts: [Product] = []

    /// 방금 팁 결제가 완료됨(감사 메시지 표시용; 잠시 후 자동 해제).
    @Published public var showTipThanks = false

    @Published public private(set) var isPurchasing = false

    private var updatesTask: Task<Void, Never>?

    public init() {
        // 앱 밖(승인 대기 등)에서 완료된 트랜잭션을 마무리한다.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                    _ = self
                }
            }
        }
        Task { await loadProducts() }
    }

    deinit { updatesTask?.cancel() }

    public func loadProducts() async {
        do {
            let products = try await Product.products(for: Self.tipIDs)
            tipProducts = products.sorted { $0.price < $1.price }
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
            if case .success(let verification) = result,
               case .verified(let transaction) = verification {
                showTipThanks = true
                await transaction.finish()
                Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    await MainActor.run { self.showTipThanks = false }
                }
            }
        } catch {
            // 결제 실패는 시스템 시트가 이미 사용자에게 보여준다.
        }
    }
}
