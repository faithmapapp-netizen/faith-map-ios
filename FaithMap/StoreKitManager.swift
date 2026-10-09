import StoreKit
import WebKit

/// Faith Map StoreKit 2 manager — handles Plus subscriptions and lifetime purchase.
/// Product IDs match App Store Connect:
///   faithmap_plus_monthly  ($7.99/mo)
///   faithmap_plus_yearly   ($59.99/yr)
///   faithmap_plus_lifetime ($149.99 one-time)
@available(iOS 15.0, *)
class StoreKitManager: NSObject, ObservableObject {
    static let shared = StoreKitManager()

    static let productIDs = [
        "faithmap_plus_monthly",
        "faithmap_plus_yearly",
        "faithmap_plus_lifetime",
    ]

    @Published var products: [Product] = []
    @Published var purchasedProductIDs: Set<String> = []

    private var updateListenerTask: Task<Void, Error>?

    private weak var webView: WKWebView?

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    override init() {
        super.init()
        updateListenerTask = listenForTransactions()
        Task {
            await requestProducts()
            await updatePurchasedProducts()
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    /// Fetch products from the App Store.
    func requestProducts() async {
        do {
            let storeProducts = try await Product.products(for: Self.productIDs)
            await MainActor.run {
                self.products = storeProducts.sorted { $0.price < $1.price }
            }
        } catch {
            print("[StoreKit] Failed to fetch products: \(error)")
        }
    }

    /// Purchase a product by ID. Called from the JS bridge.
    func purchase(productID: String) async {
        guard let product = products.first(where: { $0.id == productID }) else {
            notifyWeb(type: "purchaseFailed", productID: productID, message: "Product not found")
            return
        }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await updatePurchasedProducts()
                await transaction.finish()
                // Send the transaction info to the web app for backend verification
                notifyWeb(type: "purchaseSucceeded", productID: productID,
                          message: String(transaction.id))
            case .userCancelled:
                notifyWeb(type: "purchaseCancelled", productID: productID, message: "")
            case .pending:
                notifyWeb(type: "purchasePending", productID: productID, message: "")
            @unknown default:
                notifyWeb(type: "purchaseFailed", productID: productID, message: "Unknown result")
            }
        } catch {
            notifyWeb(type: "purchaseFailed", productID: productID, message: error.localizedDescription)
        }
    }

    /// Restore previous purchases.
    func restore() async {
        do {
            try await AppStore.sync()
            await updatePurchasedProducts()
            notifyWeb(type: "restoreCompleted", productID: "", message: "")
        } catch {
            notifyWeb(type: "purchaseFailed", productID: "", message: error.localizedDescription)
        }
    }

    /// Check current entitlements.
    func updatePurchasedProducts() async {
        var purchased: Set<String> = []
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                if transaction.revocationDate == nil {
                    purchased.insert(transaction.productID)
                }
            } catch {
                print("[StoreKit] Unverified transaction: \(error)")
            }
        }
        await MainActor.run {
            self.purchasedProductIDs = purchased
        }
        // Notify web of current Plus status
        let hasPlus = !purchased.isEmpty
        notifyWeb(type: "entitlementsUpdated", productID: "", message: hasPlus ? "plus" : "free")
    }

    func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            for await result in Transaction.updates {
                do {
                    let transaction = try await self.checkVerified(result)
                    await self.updatePurchasedProducts()
                    await transaction.finish()
                } catch {
                    print("[StoreKit] Transaction failed verification: \(error)")
                }
            }
        }
    }

    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreKitError.unverified
        case .verified(let safe):
            return safe
        }
    }

    enum StoreKitError: Error {
        case unverified
    }

    /// Send a message back to the web app via JS.
    private func notifyWeb(type: String, productID: String, message: String) {
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        let js = "window.dispatchEvent(new CustomEvent('faithmap-storekit', {detail:{type:'\(type)',productID:'\(productID)',message:'\(escaped)'}}))"
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// Handle messages from the web app JS bridge.
    func handleJSMessage(_ body: [String: Any]) {
        guard let action = body["action"] as? String else { return }
        switch action {
        case "getProducts":
            Task { await requestProducts()
                let ids = products.map { $0.id }.joined(separator: ",")
                notifyWeb(type: "productsLoaded", productID: "", message: ids)
            }
        case "purchase":
            if let productID = body["productID"] as? String {
                Task { await purchase(productID: productID) }
            }
        case "restore":
            Task { await restore() }
        case "checkEntitlements":
            Task { await updatePurchasedProducts() }
        default:
            break
        }
    }
}
