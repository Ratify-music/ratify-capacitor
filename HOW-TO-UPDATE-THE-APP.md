# Ratify Music iOS: how to use the source code and update the app

## 1. Most updates need no new app version

The iOS app loads your live site, **https://ratifymusic.com**. Anything you change in Base44
reaches the app as soon as you click **Publish**: pages, games, categories, prices, text and
features. People just close and reopen the app.

You only need a new app build (section 3) for changes to the app itself:

- the app icon or launch screen
- the app name on the home screen
- the website address the app opens
- the Apple Music plugin, or other native code
- permissions (camera, location, Apple Music)
- the version number Apple shows

## 2. Things to keep working in Base44

These parts of your Base44 code connect the website to the app. If you ask Base44's AI to
change them, tell it not to remove the "native" parts:

| File in Base44 | What it does in the app |
|---|---|
| `src/lib/nativeMusicKit.js` | Talks to the app's Apple Music plugin |
| `src/components/contexts/MusicKitContext.jsx` | Inside the app, Connect, Disconnect and Play must use the native plugin, not the web sign-in |
| `base44/shared/origin.ts` | Must keep `ratifymusic.com` so Stripe returns to the right place |
| `base44/functions/stripeWebhook`, `addCredits`, `processPremiumSubscription`, `processLiveHostSubscription` | Grant credits, Premium and Live Host after payment |

If Apple Music stops working in the app after a Base44 change, check `MusicKitContext.jsx` first.

## 3. Building a new app version (needs a Mac)

### What you need
- A Mac with **Xcode 26** or newer (free from the Mac App Store)
- **Node.js 20** or newer (https://nodejs.org)
- An Apple ID on the **Ratify LLC** developer team, added in Xcode › Settings › Accounts

### First time
1. Unzip `RatifyMusic-iOS-source.zip`.
2. Open **Terminal**, go into the folder and install the tools:
   ```
   cd ratify-music-ios
   npm install
   npx cap sync ios
   ```
3. Open the project in Xcode:
   ```
   npx cap open ios
   ```

### Every new version
1. In Xcode, click **App** (the blue icon at the top left), then the **App** target, then **General**:
   - **Version**: the number Apple shows, e.g. `3.1`
   - **Build**: must be higher than every build already uploaded, e.g. `6`, then `7`, …
2. At the top of Xcode, choose **Any iOS Device (arm64)** as the destination.
3. Choose **Product › Archive** and wait for the Organizer window.
4. Click **Distribute App › App Store Connect › Upload** and keep the default options.
5. In **App Store Connect › Ratify Music**:
   - create a new version, or use the current one;
   - after 10–30 minutes, select the new build under **Build**;
   - click **Submit for Review**.

## 4. Common changes

| Change | Where | Then |
|---|---|---|
| App icon | Replace `assets-source/ratify-black-base44.png` (1024×1024), then run `npm run assets` | New build |
| Home screen name | `ios/App/App/Info.plist` → `CFBundleDisplayName` | New build |
| Permission messages | `ios/App/App/Info.plist` → the `NS…UsageDescription` texts | New build |
| Website address | `capacitor.config.ts` (`PRODUCTION_ORIGIN`), `ios/App/App/App.entitlements`, `www/shell-bridge.js`, `www/index.html`, then run `npx cap sync ios` | New build. The new domain must be connected in Base44. |
| Apple Music behaviour | `ios/App/App/NativeMusicKitPlugin.swift` | New build |

After editing any file in `www/` or `capacitor.config.ts`, run `npx cap sync ios` before archiving.

## 5. Important: don't change

- **Bundle ID** `com.base69900c52dad19ccce6c947de.app`. It's tied to your App Store listing,
  your Apple team (`97Z6JVW7XJ`) and the sign-in links Base44 serves for your domain.
- **iPhone only.** The app is set to iPhone only, so Apple doesn't require iPad screenshots.

## 6. Apple Music notes

- Members tap **Connect Apple Music**, then **Allow** on Apple's prompt.
- Full songs need an active **Apple Music subscription** on that iPhone. The Apple ID must also
  have opened Apple's Music app once and accepted its terms. The app explains this if not.

## 7. More detail

`README.md` in the same folder has the technical details (how the app is built, the Apple
Music plugin's functions, Stripe handling).
