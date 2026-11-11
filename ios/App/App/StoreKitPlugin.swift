import Foundation
import StoreKit
import Capacitor

/// Apple In-App Purchase (StoreKit 2) for the Ratify site, iOS app only.
///
/// The site calls it through `window.Capacitor.Plugins.StoreKit`
/// (src/lib/nativePurchases.js in the Base44 repo) instead of opening Stripe:
///
///     getProducts({ productIds })                 -> { products: [{ id, displayName, description, price, displayPrice, type }] }
///     purchase({ productId, appAccountToken })    -> { productId, transactionId, originalTransactionId, appAccountToken? }
///     unfinishedTransactions()                    -> { transactions: [...] }
///     finishTransaction({ transactionId })        -> {}
///     restorePurchases()                          -> { transactions: [...] }   (current subscriptions)
///     manageSubscriptions()                       -> {}
///     addListener('transactionUpdate', cb)        purchases that complete later (Ask to Buy, renewals)
///
/// Products (App Store Connect, same ids on Google Play):
///   ratify_credits_1 / ratify_credits_3  consumables (the packs the Credit Store
///                                        shows; 5 / 11 / 24 are mapped too)
///   subscription group "Ratify Membership", one tier at a time:
///     ratify_live_host_monthly           level 1, includes Premium
///     ratify_premium_monthly             level 2
///     ratify_credit_plan_monthly         level 3, 7 credits a month
///
/// Transactions are never finished here. The page sends each one to the
/// verifyApplePurchase function, which reads it from Apple and grants the
/// credits or subscription, and only then calls finishTransaction. A purchase
/// that never reaches the server stays in Transaction.unfinished and is
/// retried on the next launch, so nothing a member pays for is lost.
///
/// `appAccountToken` is a UUID the server creates before the purchase
/// (startApplePurchase). Apple stores it on the transaction, so the purchase is
/// always applied to the account that started it.
@objc(StoreKitPlugin)
public class StoreKitPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "StoreKitPlugin"
    public let jsName = "StoreKit"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "getProducts", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "purchase", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "unfinishedTransactions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "finishTransaction", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "restorePurchases", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "manageSubscriptions", returnType: CAPPluginReturnPromise),
    ]

    private var updatesTask: Task<Void, Never>?

    override public func load() {
        // Purchases can also complete outside purchase(): an Ask to Buy approval,
        // a renewal, or a purchase made on another device. Hand them to the page
        // to verify; the server ignores ones it has already applied.
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else { continue }
                self?.notifyListeners("transactionUpdate", data: Self.payload(transaction))
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    @objc func getProducts(_ call: CAPPluginCall) {
        guard let ids = call.getArray("productIds", String.self), !ids.isEmpty else {
            call.reject("productIds is required")
            return
        }
        Task {
            do {
                let products = try await Product.products(for: ids)
                CAPLog.print("⚡️  StoreKit: asked \(ids.count) products, got \(products.map(\.id))")
                call.resolve(["products": products.map { product in
                    [
                        "id": product.id,
                        "displayName": product.displayName,
                        "description": product.description,
                        "price": NSDecimalNumber(decimal: product.price).doubleValue,
                        "displayPrice": product.displayPrice,
                        "type": Self.typeName(product.type),
                    ]
                }])
            } catch {
                CAPLog.print("⚡️  StoreKit: products failed: \(error)")
                call.reject("Failed to load products: \(error.localizedDescription)")
            }
        }
    }

    @objc func purchase(_ call: CAPPluginCall) {
        guard let productId = call.getString("productId") else {
            call.reject("productId is required")
            return
        }
        guard let tokenString = call.getString("appAccountToken"),
              let token = UUID(uuidString: tokenString) else {
            call.reject("appAccountToken must be a UUID")
            return
        }
        Task {
            do {
                guard let product = try await Product.products(for: [productId]).first else {
                    call.reject("This purchase isn't available in the App Store right now.", "UNAVAILABLE")
                    return
                }
                let result = try await product.purchase(options: [.appAccountToken(token)])
                switch result {
                case .success(.verified(let transaction)):
                    call.resolve(Self.payload(transaction))
                case .success(.unverified(_, let error)):
                    call.reject("The App Store could not verify this purchase: \(error.localizedDescription)", "UNVERIFIED")
                case .userCancelled:
                    call.reject("Purchase cancelled", "CANCELLED")
                case .pending:
                    call.reject("Your purchase is waiting for approval. It will be added once it's approved.", "PENDING")
                @unknown default:
                    call.reject("Unknown purchase result")
                }
            } catch {
                call.reject("Purchase failed: \(error.localizedDescription)")
            }
        }
    }

    /// Purchases Apple has charged for that the server has not confirmed yet.
    @objc func unfinishedTransactions(_ call: CAPPluginCall) {
        Task {
            var pending: [[String: Any]] = []
            for await result in Transaction.unfinished {
                if case .verified(let transaction) = result {
                    pending.append(Self.payload(transaction))
                }
            }
            call.resolve(["transactions": pending])
        }
    }

    /// Called from JS once verifyApplePurchase has applied the transaction.
    @objc func finishTransaction(_ call: CAPPluginCall) {
        guard let transactionId = call.getString("transactionId") else {
            call.reject("transactionId is required")
            return
        }
        Task {
            for await result in Transaction.unfinished {
                if case .verified(let transaction) = result, String(transaction.id) == transactionId {
                    await transaction.finish()
                    break
                }
            }
            call.resolve([:])
        }
    }

    /// "Restore Purchases" (required by App Review for subscriptions): syncs with
    /// the App Store, then returns the member's active subscriptions so the page
    /// can send them to the server again.
    @objc func restorePurchases(_ call: CAPPluginCall) {
        Task {
            do {
                try await AppStore.sync()
            } catch {
                // The user can cancel the App Store sign-in; current entitlements
                // are still worth returning.
                CAPLog.print("⚡️  StoreKit: AppStore.sync failed: \(error)")
            }
            var active: [[String: Any]] = []
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result {
                    active.append(Self.payload(transaction))
                }
            }
            call.resolve(["transactions": active])
        }
    }

    /// Opens Apple's own subscription management sheet (cancel, change plan).
    @objc func manageSubscriptions(_ call: CAPPluginCall) {
        Task { @MainActor in
            guard let scene = self.bridge?.viewController?.view.window?.windowScene else {
                call.reject("No window to show subscriptions in")
                return
            }
            do {
                try await AppStore.showManageSubscriptions(in: scene)
                call.resolve([:])
            } catch {
                call.reject("Could not open subscriptions: \(error.localizedDescription)")
            }
        }
    }

    private static func payload(_ transaction: Transaction) -> [String: Any] {
        var data: [String: Any] = [
            "productId": transaction.productID,
            "transactionId": String(transaction.id),
            "originalTransactionId": String(transaction.originalID),
        ]
        if let token = transaction.appAccountToken {
            data["appAccountToken"] = token.uuidString.lowercased()
        }
        if let expiration = transaction.expirationDate {
            data["expiresAt"] = ISO8601DateFormatter().string(from: expiration)
        }
        return data
    }

    private static func typeName(_ type: Product.ProductType) -> String {
        switch type {
        case .consumable: return "consumable"
        case .nonConsumable: return "nonConsumable"
        case .autoRenewable: return "subscription"
        case .nonRenewable: return "nonRenewingSubscription"
        default: return "unknown"
        }
    }
}
