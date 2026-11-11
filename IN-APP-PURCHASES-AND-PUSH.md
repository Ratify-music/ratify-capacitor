# In-app purchases, Google Play billing and push notifications

What was added for order 2 (Nov 2026), and the one-time setup each store needs
before it goes live. Nothing here contains a password or key: those go into
Base44 secrets and the git-ignored `android/keystore.properties`.

## How it works

| | iOS app | Android app | Website |
|---|---|---|---|
| Credit packs, Premium, Live Host, 7-Credit Plan | Apple In-App Purchase (`StoreKitPlugin.swift`) | Google Play Billing (`PlayBillingPlugin.java`) | Stripe, unchanged |
| Push notifications | APNs | Firebase Cloud Messaging | — |
| Apple Music | MusicKit framework (`NativeMusicKitPlugin.swift`) | MusicKit JS, with Apple's sign-in in a popup over the app (`MainActivity.openPopup`) | MusicKit JS |

The site picks the right path by itself (`src/lib/nativePurchases.js` and
`src/lib/nativePush.js` in the Base44 repo). Every purchase is checked with
Apple or Google by the server before anything is granted, and goes through the
same credit / Premium / Live Host code as Stripe payments. Every in-app
notification (game invites, results, credits, Premium, Live Host…) is also
sent as a push.

Base44 functions: `startStorePurchase`, `verifyApplePurchase`,
`verifyGooglePurchase`, `appStoreNotifications`, `googlePlayNotifications`,
`registerPushDevice`, `sendPushForNotification`. New entities: `StorePurchase`,
`PushDevice`. Workflow: "Send Push on New Notification".

## Products (same ids on both stores)

| Product id | Type | Price | Grants |
|---|---|---|---|
| `ratify_credits_1` | Consumable / one-time | $1.19 | 1 Play Credit |
| `ratify_credits_3` | Consumable / one-time | $3.49 | 3 Play Credits |
| `ratify_credit_plan_monthly` | Auto-renewable, 1 month | $4.99 | 7-Credit Plan |
| `ratify_premium_monthly` | Auto-renewable, 1 month | $9.99 | Ratify Premium |
| `ratify_live_host_monthly` | Auto-renewable, 1 month | $39.99 | Live Host (includes Premium) |

App Store: put the three subscriptions in ONE subscription group, "Ratify
Membership", levels 1 Live Host, 2 Premium, 3 7-Credit Plan. A member then holds
one at a time and upgrades are prorated by Apple. The Android app does the same
on Google Play.

## Setup checklist

### Apple (account holder or admin)
1. Agreements, Tax and Banking: accept the **Paid Applications** agreement and
   finish bank and tax details. Without it, no in-app purchase loads.
2. App Store Connect → Ratify Music → Monetization: create the five products
   above (reference name, price, display name, description, review screenshot).
3. Users and Access → Integrations → **In-App Purchase**: generate a key.
   Base44 secrets: `APPLE_IAP_PRIVATE_KEY` (the .p8 file's contents),
   `APPLE_IAP_KEY_ID`, `APPLE_IAP_ISSUER_ID`.
4. App Information → **App Store Server Notifications**: Version 2, Production
   and Sandbox URL = the `appStoreNotifications` function URL (Base44 → Code →
   Functions).
5. Certificates, Identifiers & Profiles → Keys: a key with **Apple Push
   Notifications service**. Base44 secrets: `APNS_KEY_P8`, `APNS_KEY_ID`,
   `APNS_TEAM_ID` = `97Z6JVW7XJ`.
6. Sandbox tester (Users and Access → Sandbox) for test purchases.

### Google Play (owner or admin)
1. Payments profile linked to the developer account (Setup → Payments profile).
2. **Upload key reset** (Test and release → App integrity → Upload key →
   Request upload key reset) with `store/ratify_upload_certificate.pem`. Base44
   holds the current upload key; this shell signs with its own.
3. Monetize → Products: the two one-time products and three subscriptions above
   (each subscription with one monthly auto-renewing base plan).
4. Google Cloud: a service account with a JSON key; Play Console → Users and
   permissions → invite its email with "View financial data" and "Manage orders
   and subscriptions". Base44 secret: `GOOGLE_PLAY_SERVICE_ACCOUNT` (the JSON).
5. Real-time developer notifications: a Pub/Sub topic (grant
   `google-play-developer-notifications@system.gserviceaccount.com` Publisher),
   a **push** subscription to the `googlePlayNotifications` function URL, and
   the topic in Monetization setup. Optional secret `GOOGLE_RTDN_KEY`, then add
   `?key=<it>` to the push URL.
6. License testers (Setup → License testing) for test purchases.

### Firebase (Android push) — done 12 Nov 2026
- Firebase project **Ratify Music** (`ratify-music`, project number
  383336075158) on the developer's Google account, with Analytics and Gemini
  off. Android apps `com.base69900c52dad19ccce6c947de.app` and `…app.dev`.
  Ownership can be handed over any time (Project settings → Users and
  permissions → add the owner's Google account as Owner).
- `google-services.json` is in `android/app/` (git-ignored; the developer keeps
  a copy). Builds made with it register for push.
- Tested 12 Nov: a test build got an FCM token, and a push sent through the
  site's own `sendPushToUser` arrived on the device.
- Still to do: Base44 secret `FIREBASE_SERVICE_ACCOUNT_JSON` = the project's
  Admin SDK service-account key (held by the developer, never committed).

### Base44
- After syncing the repo, **Publish**. Check that the workflow "Send Push on New
  Notification" exists (Workflows); if not, create it: trigger Notification
  created → run `sendPushForNotification`.

## Building

- iOS: as before (`HOW-TO-UPDATE-THE-APP.md`). The App ID needs Push
  Notifications enabled (automatic signing adds it).
- Android: `cd android && ./gradlew bundleRelease` →
  `app/build/outputs/bundle/release/app-release.aab`, signed with the upload key
  from `android/keystore.properties`. Raise `versionCode` each upload
  (`-PratifyVersionCode=<n>`; Base44's live build is versionCode 2).
- `./gradlew assembleDebug` builds "Ratify Dev" (`…app.dev`), which installs next
  to the store app for testing. Play Billing only works in builds installed
  from Google Play (internal testing track).
