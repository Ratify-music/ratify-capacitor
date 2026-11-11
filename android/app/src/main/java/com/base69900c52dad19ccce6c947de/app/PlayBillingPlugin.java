package com.base69900c52dad19ccce6c947de.app;

import android.content.Intent;
import android.net.Uri;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import com.android.billingclient.api.AccountIdentifiers;
import com.android.billingclient.api.AcknowledgePurchaseParams;
import com.android.billingclient.api.BillingClient;
import com.android.billingclient.api.BillingClient.BillingResponseCode;
import com.android.billingclient.api.BillingClient.ProductType;
import com.android.billingclient.api.BillingClientStateListener;
import com.android.billingclient.api.BillingFlowParams;
import com.android.billingclient.api.BillingResult;
import com.android.billingclient.api.ConsumeParams;
import com.android.billingclient.api.PendingPurchasesParams;
import com.android.billingclient.api.ProductDetails;
import com.android.billingclient.api.Purchase;
import com.android.billingclient.api.PurchasesUpdatedListener;
import com.android.billingclient.api.QueryProductDetailsParams;
import com.android.billingclient.api.QueryPurchasesParams;
import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.function.Consumer;
import org.json.JSONException;

/**
 * Google Play Billing for the Ratify site, Android app only.
 *
 * The same JavaScript interface as StoreKitPlugin.swift on iOS, exported as
 * `window.Capacitor.Plugins.PlayBilling` (src/lib/nativePurchases.js in the
 * Base44 repo picks whichever the app has):
 *
 *     getProducts({ productIds })               -> { products: [{ id, displayName, description, displayPrice, type }] }
 *     purchase({ productId, appAccountToken })  -> { productId, transactionId, ... }  rejects CANCELLED / PENDING
 *     unfinishedTransactions()                  -> { transactions: [...] }
 *     finishTransaction({ transactionId })      -> {}
 *     restorePurchases()                        -> { transactions: [...] }   (active subscriptions)
 *     manageSubscriptions()                     -> {}
 *     addListener('transactionUpdate', cb)      purchases that complete later (pending payments)
 *
 * Products (Play Console, same ids as the App Store):
 *   ratify_credits_1 / ratify_credits_3 ...   one-time products, consumed
 *   ratify_premium_monthly, ratify_live_host_monthly, ratify_credit_plan_monthly
 *                                             subscriptions; buying one while
 *                                             holding another replaces it (an
 *                                             upgrade now, prorated; a downgrade
 *                                             at renewal), like an App Store
 *                                             subscription group.
 *
 * The purchase token stands in for iOS's transaction id: the page sends it to
 * the verifyGooglePurchase function, which reads the purchase from the Google
 * Play Developer API, grants it, and acknowledges or consumes it there. Only
 * then does the page call finishTransaction, which consumes credit packs here
 * too (a no-op if the server already did). Google refunds a purchase that isn't
 * acknowledged within three days, so an unconfirmed one is handed to the page
 * again on every launch until the server has applied it.
 *
 * The member's server-issued token goes to Google as obfuscatedAccountId, like
 * appAccountToken on iOS, so the server always applies a purchase to the
 * account that started it.
 */
@CapacitorPlugin(name = "PlayBilling")
public class PlayBillingPlugin extends Plugin implements PurchasesUpdatedListener {

    private BillingClient billing;
    private final List<Waiting> waiting = new ArrayList<>();
    private boolean connecting = false;

    // The purchase() call waiting for Google's purchase sheet.
    private PluginCall purchaseCall;
    private String purchaseProductId;

    private static final class Waiting {

        final PluginCall call;
        final Runnable action;

        Waiting(PluginCall call, Runnable action) {
            this.call = call;
            this.action = action;
        }
    }

    @Override
    public void load() {
        billing = BillingClient.newBuilder(getContext().getApplicationContext())
            .setListener(this)
            .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().enablePrepaidPlans().build())
            .enableAutoServiceReconnection()
            .build();
    }

    @Override
    protected void handleOnDestroy() {
        if (billing != null) {
            billing.endConnection();
        }
    }

    @PluginMethod
    public void getProducts(PluginCall call) {
        List<String> ids = stringList(call, "productIds");
        if (ids.isEmpty()) {
            call.reject("productIds is required");
            return;
        }
        withBilling(call, () ->
            queryAllProducts(call, ids, products -> {
                JSArray list = new JSArray();
                for (ProductDetails product : products) {
                    JSObject info = info(product);
                    if (info != null) list.put(info);
                }
                call.resolve(new JSObject().put("products", list));
            })
        );
    }

    @PluginMethod
    public void purchase(PluginCall call) {
        String productId = call.getString("productId");
        String token = call.getString("appAccountToken");
        if (productId == null || token == null || token.isEmpty()) {
            call.reject("productId and appAccountToken are required");
            return;
        }
        synchronized (this) {
            if (purchaseCall != null) {
                call.reject("Another purchase is in progress", "BUSY");
                return;
            }
        }
        withBilling(call, () ->
            queryAllProducts(call, Collections.singletonList(productId), products -> {
                ProductDetails product = products.isEmpty() ? null : products.get(0);
                if (product == null) {
                    call.reject("This purchase isn't available on Google Play right now.", "UNAVAILABLE");
                    return;
                }
                boolean subscription = ProductType.SUBS.equals(product.getProductType());
                if (!subscription) {
                    launch(call, product, null, null, token);
                    return;
                }
                ProductDetails.SubscriptionOfferDetails offer = basePlan(product);
                if (offer == null) {
                    call.reject("This subscription has no active plan on Google Play.", "UNAVAILABLE");
                    return;
                }
                // A member holds one Ratify subscription at a time: moving to
                // another replaces the current one, as in the App Store's
                // subscription group.
                queryPurchases(call, ProductType.SUBS, active -> {
                    Purchase replace = null;
                    for (Purchase purchase : active) {
                        if (!purchase.getProducts().contains(productId)) {
                            replace = purchase;
                            break;
                        }
                    }
                    launch(call, product, offer.getOfferToken(), replace, token);
                });
            })
        );
    }

    /** Live Host > Premium > 7-Credit Plan, as the App Store group's levels. */
    private static int rank(String productId) {
        if (productId.contains("live_host")) return 3;
        if (productId.contains("premium")) return 2;
        return 1;
    }

    private void launch(PluginCall call, ProductDetails product, @Nullable String offerToken, @Nullable Purchase replace, String accountToken) {
        BillingFlowParams.ProductDetailsParams.Builder item = BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(product);
        if (offerToken != null) {
            item.setOfferToken(offerToken);
        } else {
            List<ProductDetails.OneTimePurchaseOfferDetails> offers = product.getOneTimePurchaseOfferDetailsList();
            if (offers != null && !offers.isEmpty() && offers.get(0).getOfferToken() != null) {
                item.setOfferToken(offers.get(0).getOfferToken());
            }
        }
        BillingFlowParams.Builder params = BillingFlowParams.newBuilder()
            .setProductDetailsParamsList(Collections.singletonList(item.build()))
            .setObfuscatedAccountId(accountToken);
        if (replace != null) {
            // Upgrade: starts now, charging only the difference for the rest of
            // the current period (the renewal date stays). Downgrade: starts at
            // the next renewal. Both as on the App Store.
            String current = replace.getProducts().isEmpty() ? "" : replace.getProducts().get(0);
            int mode = rank(product.getProductId()) > rank(current)
                ? BillingFlowParams.SubscriptionUpdateParams.ReplacementMode.CHARGE_PRORATED_PRICE
                : BillingFlowParams.SubscriptionUpdateParams.ReplacementMode.DEFERRED;
            params.setSubscriptionUpdateParams(
                BillingFlowParams.SubscriptionUpdateParams.newBuilder()
                    .setOldPurchaseToken(replace.getPurchaseToken())
                    .setSubscriptionReplacementMode(mode)
                    .build()
            );
        }
        synchronized (this) {
            purchaseCall = call;
            purchaseProductId = product.getProductId();
        }
        getActivity()
            .runOnUiThread(() -> {
                BillingResult result = billing.launchBillingFlow(getActivity(), params.build());
                if (result.getResponseCode() != BillingResponseCode.OK) {
                    onPurchasesUpdated(result, null);
                }
            });
    }

    @Override
    public void onPurchasesUpdated(@NonNull BillingResult result, @Nullable List<Purchase> purchases) {
        PluginCall call;
        String productId;
        synchronized (this) {
            call = purchaseCall;
            productId = purchaseProductId;
            purchaseCall = null;
            purchaseProductId = null;
        }
        int code = result.getResponseCode();

        if (code == BillingResponseCode.OK && purchases != null) {
            for (Purchase purchase : purchases) {
                boolean purchased = purchase.getPurchaseState() == Purchase.PurchaseState.PURCHASED;
                if (call != null && purchase.getProducts().contains(productId)) {
                    if (purchased) {
                        call.resolve(info(purchase));
                    } else {
                        call.reject("Your purchase is waiting for payment. It will be added once Google Play confirms it.", "PENDING");
                    }
                    call = null;
                } else if (purchased) {
                    // A pending payment that completed, or a purchase made
                    // outside the app (promo code).
                    notifyListeners("transactionUpdate", info(purchase), true);
                }
            }
            if (call != null) {
                call.reject("Your purchase is waiting for payment. It will be added once Google Play confirms it.", "PENDING");
            }
        } else if (call == null) {
            return;
        } else if (code == BillingResponseCode.USER_CANCELED) {
            call.reject("Purchase cancelled", "CANCELLED");
        } else if (code == BillingResponseCode.ITEM_ALREADY_OWNED) {
            // Owned by this Google account and not yet confirmed (a credit pack
            // not consumed, or the subscription). Like StoreKit, answer with it;
            // the server checks whom it belongs to.
            PluginCall owned = call;
            String wanted = productId;
            queryAllPurchases(owned, all -> {
                for (Purchase purchase : all) {
                    if (purchase.getProducts().contains(wanted)) {
                        owned.resolve(info(purchase));
                        return;
                    }
                }
                owned.reject("You already own this on Google Play.", "ALREADY_OWNED");
            });
        } else {
            reject(call, result);
        }
    }

    /** Purchases Google has charged for that the server has not confirmed yet. */
    @PluginMethod
    public void unfinishedTransactions(PluginCall call) {
        withBilling(call, () ->
            queryAllPurchases(call, all -> {
                JSArray list = new JSArray();
                for (Purchase purchase : all) {
                    // Every one-time purchase still listed is unconsumed;
                    // subscriptions only until acknowledged.
                    if (!isSubscription(purchase) || !purchase.isAcknowledged()) {
                        list.put(info(purchase));
                    }
                }
                call.resolve(new JSObject().put("transactions", list));
            })
        );
    }

    /** Called from JS once verifyGooglePurchase has applied the purchase. */
    @PluginMethod
    public void finishTransaction(PluginCall call) {
        String token = call.getString("transactionId");
        if (token == null || token.isEmpty()) {
            call.reject("transactionId is required");
            return;
        }
        withBilling(call, () ->
            queryAllPurchases(call, all -> {
                for (Purchase purchase : all) {
                    if (!token.equals(purchase.getPurchaseToken())) continue;
                    if (!isSubscription(purchase)) {
                        ConsumeParams params = ConsumeParams.newBuilder().setPurchaseToken(token).build();
                        billing.consumeAsync(params, (result, consumed) -> call.resolve());
                        return;
                    }
                    if (!purchase.isAcknowledged()) {
                        AcknowledgePurchaseParams params = AcknowledgePurchaseParams.newBuilder().setPurchaseToken(token).build();
                        billing.acknowledgePurchase(params, result -> call.resolve());
                        return;
                    }
                }
                // Unknown, or already consumed / acknowledged by the server.
                call.resolve();
            })
        );
    }

    /**
     * "Restore Purchases": Google Play keeps purchases with the Google account,
     * so this returns its active subscriptions for the page to send to the
     * server again.
     */
    @PluginMethod
    public void restorePurchases(PluginCall call) {
        withBilling(call, () ->
            queryPurchases(call, ProductType.SUBS, active -> {
                JSArray list = new JSArray();
                for (Purchase purchase : active) list.put(info(purchase));
                call.resolve(new JSObject().put("transactions", list));
            })
        );
    }

    /** Google Play's subscription page for this app (change plan, cancel). */
    @PluginMethod
    public void manageSubscriptions(PluginCall call) {
        String url = "https://play.google.com/store/account/subscriptions?package=" + getContext().getPackageName();
        String productId = call.getString("productId");
        if (productId != null && !productId.isEmpty()) {
            url += "&sku=" + Uri.encode(productId);
        }
        try {
            getActivity().startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
            call.resolve();
        } catch (Exception e) {
            call.reject("Could not open Google Play subscriptions: " + e.getMessage());
        }
    }

    /** Runs `action` once Google Play Billing is connected; rejects `call` if it can't be. */
    private void withBilling(@Nullable PluginCall call, Runnable action) {
        if (billing.isReady()) {
            action.run();
            return;
        }
        synchronized (waiting) {
            waiting.add(new Waiting(call, action));
            if (connecting) {
                return;
            }
            connecting = true;
        }
        billing.startConnection(
            new BillingClientStateListener() {
                @Override
                public void onBillingSetupFinished(@NonNull BillingResult result) {
                    List<Waiting> ready;
                    synchronized (waiting) {
                        ready = new ArrayList<>(waiting);
                        waiting.clear();
                        connecting = false;
                    }
                    for (Waiting next : ready) {
                        if (result.getResponseCode() == BillingResponseCode.OK) {
                            next.action.run();
                        } else if (next.call != null) {
                            reject(next.call, result);
                        }
                    }
                }

                @Override
                public void onBillingServiceDisconnected() {
                    // enableAutoServiceReconnection() reconnects on the next call.
                }
            }
        );
    }

    /** Product details for ids of either type (one-time products and subscriptions). */
    private void queryAllProducts(PluginCall call, List<String> ids, Consumer<List<ProductDetails>> then) {
        queryProducts(call, ids, ProductType.INAPP, oneTime ->
            queryProducts(call, ids, ProductType.SUBS, subs -> {
                List<ProductDetails> all = new ArrayList<>(oneTime);
                all.addAll(subs);
                then.accept(all);
            })
        );
    }

    private void queryProducts(PluginCall call, List<String> ids, String type, Consumer<List<ProductDetails>> then) {
        List<QueryProductDetailsParams.Product> products = new ArrayList<>();
        for (String id : ids) {
            products.add(QueryProductDetailsParams.Product.newBuilder().setProductId(id).setProductType(type).build());
        }
        billing.queryProductDetailsAsync(QueryProductDetailsParams.newBuilder().setProductList(products).build(), (result, details) -> {
            if (result.getResponseCode() != BillingResponseCode.OK) {
                reject(call, result);
                return;
            }
            then.accept(details.getProductDetailsList());
        });
    }

    private void queryAllPurchases(@Nullable PluginCall call, Consumer<List<Purchase>> then) {
        queryPurchases(call, ProductType.INAPP, oneTime ->
            queryPurchases(call, ProductType.SUBS, subs -> {
                List<Purchase> all = new ArrayList<>(oneTime);
                all.addAll(subs);
                then.accept(all);
            })
        );
    }

    /** Purchased (not pending) purchases of one type; Play only returns current ones. */
    private void queryPurchases(@Nullable PluginCall call, String type, Consumer<List<Purchase>> then) {
        QueryPurchasesParams params = QueryPurchasesParams.newBuilder().setProductType(type).build();
        billing.queryPurchasesAsync(params, (result, purchases) -> {
            if (result.getResponseCode() != BillingResponseCode.OK) {
                if (call != null) {
                    reject(call, result);
                }
                return;
            }
            List<Purchase> purchased = new ArrayList<>();
            for (Purchase purchase : purchases) {
                if (purchase.getPurchaseState() == Purchase.PurchaseState.PURCHASED) {
                    purchased.add(purchase);
                }
            }
            then.accept(purchased);
        });
    }

    /** Ratify's subscription products all start with this; credit packs don't. */
    private static boolean isSubscription(Purchase purchase) {
        for (String id : purchase.getProducts()) {
            if (id.endsWith("_monthly")) return true;
        }
        return false;
    }

    /** The plain base plan (no introductory offer), the one the site's prices describe. */
    @Nullable
    private static ProductDetails.SubscriptionOfferDetails basePlan(ProductDetails product) {
        List<ProductDetails.SubscriptionOfferDetails> offers = product.getSubscriptionOfferDetails();
        if (offers == null) {
            return null;
        }
        for (ProductDetails.SubscriptionOfferDetails offer : offers) {
            if (offer.getOfferId() == null) {
                return offer;
            }
        }
        return offers.isEmpty() ? null : offers.get(0);
    }

    private static JSObject info(Purchase purchase) {
        AccountIdentifiers account = purchase.getAccountIdentifiers();
        String accountId = account == null ? null : account.getObfuscatedAccountId();
        List<String> products = purchase.getProducts();
        JSObject object = new JSObject();
        // The purchase token is what the server verifies with Google. For a
        // subscription it stays the same across renewals.
        object.put("transactionId", purchase.getPurchaseToken());
        object.put("originalTransactionId", purchase.getPurchaseToken());
        object.put("orderId", purchase.getOrderId() == null ? "" : purchase.getOrderId());
        object.put("productId", products.isEmpty() ? "" : products.get(0));
        if (accountId != null && !accountId.isEmpty()) object.put("appAccountToken", accountId);
        object.put("platform", "android");
        return object;
    }

    @Nullable
    private static JSObject info(ProductDetails product) {
        JSObject object = new JSObject();
        object.put("id", product.getProductId());
        object.put("displayName", product.getName());
        object.put("description", product.getDescription());
        if (ProductType.SUBS.equals(product.getProductType())) {
            ProductDetails.SubscriptionOfferDetails offer = basePlan(product);
            if (offer == null) return null;
            List<ProductDetails.PricingPhase> phases = offer.getPricingPhases().getPricingPhaseList();
            // The last phase is the recurring price (earlier ones would be intro prices).
            ProductDetails.PricingPhase price = phases.get(phases.size() - 1);
            object.put("displayPrice", price.getFormattedPrice());
            object.put("price", price.getPriceAmountMicros() / 1_000_000.0);
            object.put("type", "subscription");
        } else {
            List<ProductDetails.OneTimePurchaseOfferDetails> offers = product.getOneTimePurchaseOfferDetailsList();
            ProductDetails.OneTimePurchaseOfferDetails offer = offers != null && !offers.isEmpty() ? offers.get(0) : product.getOneTimePurchaseOfferDetails();
            if (offer == null) return null;
            object.put("displayPrice", offer.getFormattedPrice());
            object.put("price", offer.getPriceAmountMicros() / 1_000_000.0);
            object.put("type", "consumable");
        }
        return object;
    }

    private static List<String> stringList(PluginCall call, String key) {
        List<String> list = new ArrayList<>();
        JSArray array = call.getArray(key);
        if (array == null) {
            return list;
        }
        try {
            for (Object value : array.toList()) {
                if (value instanceof String) {
                    list.add((String) value);
                }
            }
        } catch (JSONException e) {
            // Not an array of strings: no products.
        }
        return list;
    }

    private static void reject(PluginCall call, BillingResult result) {
        String code;
        String message;
        switch (result.getResponseCode()) {
            case BillingResponseCode.BILLING_UNAVAILABLE:
                code = "UNAVAILABLE";
                message = "Google Play purchases aren't available. Check that you're signed in to the Play Store.";
                break;
            case BillingResponseCode.ITEM_UNAVAILABLE:
                code = "UNAVAILABLE";
                message = "This purchase isn't available on Google Play right now.";
                break;
            case BillingResponseCode.NETWORK_ERROR:
            case BillingResponseCode.SERVICE_UNAVAILABLE:
            case BillingResponseCode.SERVICE_DISCONNECTED:
                code = "NETWORK";
                message = "Couldn't reach Google Play. Check your connection and try again.";
                break;
            case BillingResponseCode.DEVELOPER_ERROR:
                // Usually an app not installed from Google Play, or a product
                // that isn't active in Play Console.
                code = "FAILED";
                message = "Google Play couldn't start this purchase (" + result.getDebugMessage() + ").";
                break;
            default:
                code = "FAILED";
                String debug = result.getDebugMessage();
                message = debug == null || debug.isEmpty() ? "Google Play Billing error " + result.getResponseCode() : debug;
        }
        call.reject(message, code);
    }
}
