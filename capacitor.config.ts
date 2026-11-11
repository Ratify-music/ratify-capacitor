import type { CapacitorConfig } from '@capacitor/cli';

/**
 * Ratify Music: self-managed Capacitor iOS and Android shell around the Base44 app.
 *
 * The shell loads the published Base44 site on its custom domain,
 * ratifymusic.com (connected in Base44, DNS at GoDaddy, 16 Oct 2026), over
 * `server.url`. It does not bundle a build, so anything published in Base44 reaches the app without a
 * new TestFlight or App Store build, as it did with Base44's own wrapper.
 *
 * What the shell adds natively:
 *   - NativeMusicKit: Apple Music authorisation and full-song playback through
 *     the MusicKit framework, for the bridge the site already has
 *     (src/lib/nativeMusicKit.js in the Base44 repo).
 *   - Base44Auth: "Continue with Apple / Google / Facebook / Microsoft" in an
 *     ASWebAuthenticationSession (iOS) or a Custom Tab (Android), because
 *     Google refuses OAuth in WebViews.
 *   - StoreKit (iOS) / PlayBilling (Android): in-app purchases of credits,
 *     Premium, Live Host and the 7-Credit Plan for the site's store pages
 *     (src/lib/nativePurchases.js in the Base44 repo).
 *   - PushNotifications (Capacitor plugin): every in-app notification also
 *     arrives as a push (src/lib/nativePush.js).
 *   - Android: Apple Music sign-in in a popup window over the app
 *     (MainActivity.openPopup), where MusicKit JS hands the token back.
 *
 * `www/` holds only the offline screen (`server.errorPath`) and
 * shell-bridge.js, which the native side injects into the site's pages.
 */
const PRODUCTION_ORIGIN = 'https://ratifymusic.com';

/**
 * The app's Base44 address before the custom domain, which still serves the
 * same app. The first TestFlight builds loaded it, and older links and saved
 * passwords point at it. Base44Auth sends any link to it to the same page on
 * ratifymusic.com, where the member is signed in.
 */
const LEGACY_HOSTS = ['master-ratify-music-v1production-copy.base44.app'];

/**
 * Release safety lock. A dev shell may point somewhere else, but only with
 * CAPACITOR_ALLOW_DEV_ORIGIN=1 set explicitly. Otherwise an override fails the
 * build loudly instead of quietly shipping a preview or localhost URL.
 */
function resolveAppOrigin(): string {
  const override = process.env['CAPACITOR_APP_ORIGIN'];
  if (!override || override === PRODUCTION_ORIGIN) return PRODUCTION_ORIGIN;
  if (process.env['CAPACITOR_ALLOW_DEV_ORIGIN'] === '1') return override;
  throw new Error(
    `Refusing to build the Ratify shell against "${override}". ` +
      `Release builds must use ${PRODUCTION_ORIGIN}. ` +
      `For a development shell, set CAPACITOR_ALLOW_DEV_ORIGIN=1.`,
  );
}

const APP_ORIGIN = resolveAppOrigin();
const IS_DEV_ORIGIN = APP_ORIGIN !== PRODUCTION_ORIGIN;

// The site's theme colour (index.html `theme-color`, dark only). Used for the
// WebView, the launch screen and the offline page, so nothing flashes white.
const SURFACE = '#080808';

const config: CapacitorConfig = {
  // The identity of the Base44-built iOS app already in TestFlight: Base44
  // names its builds com.base<app id>.app, and the site's
  // apple-app-site-association (on ratifymusic.com and on the base44.app
  // address) lists 97Z6JVW7XJ.com.base69900c52dad19ccce6c947de.app.
  // Keeping it makes this build the next one of that app (same testers, same
  // App Store record), and keeps the domain association that Password AutoFill
  // and the sign-in callback rely on.
  appId: 'com.base69900c52dad19ccce6c947de.app',
  appName: 'Ratify Music',
  webDir: 'www',
  // Lets the site tell the native shell apart by user agent if it ever needs to.
  appendUserAgent: 'RatifyApp',
  backgroundColor: SURFACE,

  server: {
    url: APP_ORIGIN,
    iosScheme: 'https',
    cleartext: IS_DEV_ORIGIN,
    // Relative to `webDir`. Shown when the site can't be reached; the page
    // checks for connectivity and retries. See www/index.html.
    errorPath: 'index.html',
    // Only the app's own host stays inside the WebView. Every other top-level
    // navigation leaves for Safari or the system, on purpose:
    //   - Stripe Checkout and the billing portal (checkout.stripe.com,
    //     billing.stripe.com) must open in Safari, where Apple Pay works. The
    //     site sends the page there with `window.location.href = url`, and
    //     Capacitor hands any off-site top-level navigation to
    //     UIApplication.open. Do NOT add Stripe hosts here.
    //   - ratifynation.com (privacy and terms links), mailto:, tel:.
    // Social sign-in is the exception: the Base44Auth plugin catches it before
    // this list is consulted (ios/App/App/Base44AuthPlugin.swift), as it does
    // links to the old base44.app address (LEGACY_HOSTS).
    allowNavigation: [new URL(APP_ORIGIN).host],
  },

  ios: {
    // The site sets viewport-fit=cover and pads itself with
    // env(safe-area-inset-*) (globals.css .safe-pt / .safe-pb), so the WebView
    // runs edge to edge with no automatic insets.
    contentInset: 'never',
    backgroundColor: SURFACE,
    // App-bound domains would block Stripe, the sign-in providers and Apple
    // Music artwork hosts, and cannot be relaxed at runtime.
    limitsNavigationsToAppBoundDomains: false,
    scrollEnabled: true,
  },

  android: {
    backgroundColor: SURFACE,
    allowMixedContent: false,
  },

  plugins: {
    SystemBars: {
      // Built into Capacitor 8. 'DARK' means light status-bar icons, over the
      // app's black pages.
      style: 'DARK',
      // Android only. The page reads real env() insets (WebKit on iOS; on
      // Android, MainActivity.fitSystemBars passes them through for WebView
      // 140+ and pads the layout itself on older WebViews).
      insetsHandling: 'disable',
    },
    Base44Auth: {
      legacyHosts: LEGACY_HOSTS,
    },
    PushNotifications: {
      // Show a push as a banner even while the app is open (iOS).
      presentationOptions: ['badge', 'sound', 'alert'],
    },
    // No StatusBar, Keyboard, SplashScreen or App plugin: nothing on the site
    // calls them. The launch screen is held natively until the first page has
    // painted (ShellViewController.swift, MainActivity.java).
  },
};

export default config;
