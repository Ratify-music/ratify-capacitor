package com.base69900c52dad19ccce6c947de.app;

import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.verify.domain.DomainVerificationManager;
import android.content.pm.verify.domain.DomainVerificationUserState;
import android.net.Uri;
import android.os.Build;
import android.webkit.CookieManager;
import android.webkit.WebSettings;
import android.webkit.WebView;
import androidx.browser.customtabs.CustomTabsIntent;
import com.getcapacitor.Logger;
import com.getcapacitor.Plugin;
import com.getcapacitor.annotation.CapacitorPlugin;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.Set;

/**
 * Google sign-in for the Base44 app, plus App Links into it.
 *
 * The /login page's "Continue with Google" sends the page to
 * https://ratifymusic.com/api/apps/auth/login?from_url=<page>&app_id=…, which
 * goes through app.base44.com and Google and finally comes back to
 * <from_url>?access_token=…. The app's Base44 SDK reads access_token from the
 * URL on load and keeps it in localStorage.
 *
 * Google refuses OAuth inside embedded WebViews (disallowed_useragent), so this
 * plugin catches that first navigation and runs it in a Custom Tab. Base44
 * rejects custom URL schemes as a from_url, so the tab returns to
 * https://ratifymusic.com/native-auth, an App Link this app owns (the
 * intent filter in AndroidManifest.xml, verified against the assetlinks.json
 * Base44 already serves for this package). Same flow as Base44AuthPlugin.swift.
 *
 * The App Link only reaches the app once Android has verified it, which needs
 * the Play-signed build (README → "Store identity"). Where it is not verified
 * (a debug build, a sideloaded APK, a signing key assetlinks.json doesn't
 * list), the Custom Tab could never hand the token back, so the sign-in stays
 * in the WebView instead, presenting itself as Chrome for the Google hops only.
 */
@CapacitorPlugin(name = "Base44Auth")
public class Base44AuthPlugin extends Plugin {

    // Must match the App Link path in AndroidManifest.xml and
    // Base44AuthPlugin.callbackPath on iOS.
    static final String CALLBACK_PATH = "/native-auth";

    // The return URL outlives the process: Android may kill the app while the
    // user is in the Custom Tab, and the callback then cold-starts it.
    private static final String PREFS = "base44_auth";
    private static final String KEY_RETURN_URL = "return_url";

    // Only while the WebView itself is on the Google hops (fallback path).
    private boolean inWebViewSignIn = false;
    private String savedUserAgent;

    /**
     * The app's previous addresses (`plugins.Base44Auth.legacyHosts` in
     * capacitor.config.ts): links to them open the same page on the app's
     * own host, where the member is signed in. Same as on iOS.
     */
    private final Set<String> legacyHosts = new HashSet<>();

    /**
     * Apple's Music sign-in pages. MusicKit JS normally shows them in a popup
     * (MainActivity.openPopup); the site falls back to sending the whole page
     * there, and either way they must stay in the app so the member's token
     * comes back to it instead of to Chrome.
     */
    private static final Set<String> APPLE_MUSIC_AUTH_HOSTS = new HashSet<>(
        Arrays.asList("authorize.music.apple.com", "idmsa.apple.com", "appleid.apple.com")
    );

    static boolean isAppleMusicAuthHost(String host) {
        return host != null && APPLE_MUSIC_AUTH_HOSTS.contains(host.toLowerCase(Locale.ROOT));
    }

    @Override
    public void load() {
        for (String host : getConfig().getArray("legacyHosts", new String[0])) {
            legacyHosts.add(host.toLowerCase(Locale.ROOT));
        }
    }

    @Override
    public Boolean shouldOverrideLoad(Uri url) {
        Uri server = Uri.parse(bridge.getServerUrl());
        String host = url.getHost();
        if (host == null) return null;

        if (legacyHosts.contains(host.toLowerCase(Locale.ROOT))) {
            load(url.buildUpon().scheme(server.getScheme()).authority(server.getHost()).build().toString());
            return true;
        }

        if (isAppleMusicAuthHost(host)) {
            // The site's full-page Apple Music sign-in: stays in the WebView,
            // presenting as Chrome, until Apple sends it back to the app.
            if (!inWebViewSignIn) beginInWebViewSignIn();
            return false;
        }

        if (host.equals(server.getHost())) {
            String path = url.getPath();
            if (path == null || !path.startsWith("/api/")) {
                if (inWebViewSignIn) endInWebViewSignIn();
                return null;
            }
            if (isProviderLogin(url)) {
                if (appLinkVerified(server.getHost())) {
                    signInWithCustomTab(url, server);
                    // Cancel the WebView's own navigation.
                    return true;
                }
                beginInWebViewSignIn();
            }
            followRedirects(url, server);
            return true;
        }

        if (inWebViewSignIn && ("https".equals(url.getScheme()) || "http".equals(url.getScheme()))) {
            // Every hop of the sign-in stays in the WebView until it comes
            // back to the app's own host, not only the known auth hosts:
            // after the password, Google passes through
            // accounts.youtube.com/accounts/SetSID, which Capacitor otherwise
            // hands to Chrome, taking the sign-in out of the app.
            return false;
        }
        return null;
    }

    /** /api/apps/auth/login (Google), /api/apps/auth/<provider>/login, and SSO /api/apps/<id>/auth/sso/login. */
    private static boolean isProviderLogin(Uri url) {
        List<String> parts = url.getPathSegments();
        if (parts.size() < 4 || !parts.get(0).equals("api") || !parts.get(1).equals("apps")) return false;
        if (!parts.get(parts.size() - 1).equals("login")) return false;
        return parts.get(2).equals("auth") || (parts.size() == 6 && parts.get(3).equals("auth") && parts.get(4).equals("sso"));
    }

    /**
     * Android 12+ reports whether App Links for the host are verified (or the
     * user turned them on for this app). Older versions verify at install and
     * otherwise ask the user which app to open, which still returns here.
     */
    private boolean appLinkVerified(String host) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true;
        try {
            DomainVerificationManager manager = getContext().getSystemService(DomainVerificationManager.class);
            DomainVerificationUserState state = manager.getDomainVerificationUserState(getContext().getPackageName());
            if (state == null) return false;
            Integer value = state.getHostToStateMap().get(host);
            return value != null && value != DomainVerificationUserState.DOMAIN_STATE_NONE;
        } catch (Exception e) {
            Logger.error("Base44Auth: could not read App Link state", e);
            return false;
        }
    }

    // Custom Tab (App Link verified)

    private void signInWithCustomTab(Uri loginUrl, Uri server) {
        // Where the page asked to come back to. The token is only ever handed
        // to the app's own origin, never to a host a page could put in from_url.
        String from = loginUrl.getQueryParameter("from_url");
        Uri requested = from == null ? null : Uri.parse(from);
        Uri returnUrl = requested != null && sameHost(requested, server) ? requested : server;
        prefs().edit().putString(KEY_RETURN_URL, returnUrl.toString()).apply();

        Uri callback = new Uri.Builder().scheme("https").authority(server.getHost()).path(CALLBACK_PATH).build();
        Uri.Builder start = loginUrl.buildUpon().clearQuery();
        for (String name : loginUrl.getQueryParameterNames()) {
            if (name.equals("from_url")) continue;
            for (String value : loginUrl.getQueryParameters(name)) {
                start.appendQueryParameter(name, value);
            }
        }
        start.appendQueryParameter("from_url", callback.toString());

        try {
            new CustomTabsIntent.Builder()
                .setColorScheme(CustomTabsIntent.COLOR_SCHEME_DARK)
                .setShowTitle(true)
                .build()
                .launchUrl(getActivity(), start.build());
        } catch (ActivityNotFoundException e) {
            Logger.error("Base44Auth: no browser to sign in with", e);
        }
    }

    /** Also called on a cold start, with the launch intent (BridgeActivity.load). */
    @Override
    protected void handleOnNewIntent(Intent intent) {
        Uri data = intent.getData();
        Uri server = Uri.parse(bridge.getServerUrl());
        if (data == null || !Intent.ACTION_VIEW.equals(intent.getAction()) || !sameHost(data, server)) {
            return;
        }

        if (!CALLBACK_PATH.equals(data.getPath())) {
            // Any other link to ratifymusic.com: show that page.
            load(data.toString());
            return;
        }

        String saved = prefs().getString(KEY_RETURN_URL, null);
        prefs().edit().remove(KEY_RETURN_URL).apply();
        Uri returnUrl = saved == null ? server : Uri.parse(saved);
        if (!sameHost(returnUrl, server)) returnUrl = server;

        String token = data.getQueryParameter("access_token");
        if (token == null || token.isEmpty()) {
            Logger.warn("Base44Auth: callback without a token");
            return;
        }
        Uri.Builder target = returnUrl.buildUpon().clearQuery();
        for (String name : returnUrl.getQueryParameterNames()) {
            if (name.equals("access_token") || name.equals("is_new_user")) continue;
            for (String value : returnUrl.getQueryParameters(name)) {
                target.appendQueryParameter(name, value);
            }
        }
        target.appendQueryParameter("access_token", token);
        String isNewUser = data.getQueryParameter("is_new_user");
        if (isNewUser != null) target.appendQueryParameter("is_new_user", isNewUser);

        // A real load, not a client-side route: the SDK and the app's auth
        // context read the token once, at startup.
        load(target.build().toString());
    }

    private void load(String url) {
        WebView webView = bridge.getWebView();
        webView.post(() -> webView.loadUrl(url));
    }

    // Redirects from the app's own /api/ endpoints

    /**
     * Base44's auth endpoints answer page navigations with redirects:
     * /api/apps/auth/login 307s to app.base44.com, /api/apps/auth/logout 302s
     * back to the app. Capacitor serves every page on the app's host through
     * its own proxy (to inject its bridge), and that proxy follows redirects
     * itself and hands the WebView the final page's HTML under the original
     * /api/ URL. The app then boots on a path it doesn't know and bounces to
     * /login, so sign-out and Google sign-in both went nowhere.
     *
     * Resolve those redirects here instead, with the WebView's cookies, and
     * load the first URL that is not another /api/ hop on this host. iOS has
     * no proxy and needs none of this.
     */
    private void followRedirects(Uri start, Uri server) {
        WebView webView = bridge.getWebView();
        String userAgent = webView.getSettings().getUserAgentString();
        new Thread(() -> {
            String next = start.toString();
            try {
                for (int hop = 0; hop < 5; hop++) {
                    HttpURLConnection conn = (HttpURLConnection) new URL(next).openConnection();
                    conn.setInstanceFollowRedirects(false);
                    conn.setRequestProperty("User-Agent", userAgent);
                    conn.setRequestProperty("Accept", "text/html,application/xhtml+xml,*/*;q=0.8");
                    String cookie = CookieManager.getInstance().getCookie(next);
                    if (cookie != null) conn.setRequestProperty("Cookie", cookie);
                    conn.setConnectTimeout(20_000);
                    conn.setReadTimeout(20_000);
                    int status = conn.getResponseCode();
                    List<String> setCookies = conn.getHeaderFields().get("Set-Cookie");
                    if (setCookies != null) {
                        for (String value : setCookies) CookieManager.getInstance().setCookie(next, value);
                    }
                    String location = conn.getHeaderField("Location");
                    conn.disconnect();
                    if (status < 300 || status >= 400 || location == null) break;

                    Uri target = Uri.parse(new URL(new URL(next), location).toString());
                    next = target.toString();
                    String path = target.getPath();
                    boolean anotherApiHop = sameHost(target, server) && path != null && path.startsWith("/api/");
                    if (!anotherApiHop) break;
                }
            } catch (Exception e) {
                Logger.error("Base44Auth: could not follow " + start.getPath(), e);
            }
            final String url = next;
            CookieManager.getInstance().flush();
            webView.post(() -> webView.loadUrl(url));
        }).start();
    }

    // In the WebView (App Link not verified)

    private void beginInWebViewSignIn() {
        WebView webView = bridge.getWebView();
        WebSettings settings = webView.getSettings();
        inWebViewSignIn = true;
        savedUserAgent = settings.getUserAgentString();
        // Chrome's own user agent: the WebView's minus the "; wv" token, the
        // "Version/4.0" WebViews add, and the app's appended name.
        String chrome = savedUserAgent
            .replace("; wv)", ")")
            .replaceAll("Version/\\d+(\\.\\d+)* ", "")
            .replace(" RatifyApp", "");
        settings.setUserAgentString(chrome);
    }

    private void endInWebViewSignIn() {
        inWebViewSignIn = false;
        bridge.getWebView().getSettings().setUserAgentString(savedUserAgent);
        savedUserAgent = null;
    }

    // -

    private static boolean sameHost(Uri a, Uri b) {
        return a.getHost() != null && a.getHost().equals(b.getHost()) && Objects.equals(a.getScheme(), b.getScheme());
    }

    private SharedPreferences prefs() {
        return getContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }
}
