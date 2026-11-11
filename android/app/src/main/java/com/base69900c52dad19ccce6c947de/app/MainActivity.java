package com.base69900c52dad19ccce6c947de.app;

import android.app.Dialog;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.os.Message;
import android.view.ViewGroup;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.ImageButton;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.Window;
import android.webkit.WebResourceRequest;
import android.webkit.WebView;
import android.widget.ProgressBar;
import androidx.activity.OnBackPressedCallback;
import androidx.core.graphics.Insets;
import androidx.core.splashscreen.SplashScreen;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowCompat;
import androidx.core.view.WindowInsetsCompat;
import androidx.webkit.WebSettingsCompat;
import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;
import com.getcapacitor.BridgeActivity;
import com.getcapacitor.BridgeWebChromeClient;
import com.getcapacitor.BridgeWebViewClient;
import com.getcapacitor.Logger;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

public class MainActivity extends BridgeActivity {

    // Longest the splash waits for the first page before handing over to the
    // page-load bar, so a slow network never looks like a frozen splash.
    private static final long LAUNCH_TIMEOUT_MS = 10_000;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private volatile boolean firstPagePainted = false;

    private ProgressBar pageProgress;
    // www/shell-bridge.js, or null when document-start injection is available
    // and it has already been registered.
    private String shellBridgeFallback;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        // Replaces the SplashScreen plugin, whose fixed timer either cuts to a
        // blank screen before the app has loaded or holds a loaded page back.
        // Hold the launch screen exactly until the first page has painted.
        SplashScreen splash = SplashScreen.installSplashScreen(this);
        splash.setKeepOnScreenCondition(() -> !firstPagePainted);
        splash.setOnExitAnimationListener((provider) ->
            provider.getView().animate().alpha(0f).setDuration(250).withEndAction(provider::remove).start()
        );
        handler.postDelayed(() -> firstPagePainted = true, LAUNCH_TIMEOUT_MS);

        // Local plugins aren't found by Capacitor's plugin scan, which only
        // covers packages; they must be registered before super.onCreate.
        registerPlugin(Base44AuthPlugin.class);
        registerPlugin(PlayBillingPlugin.class);

        super.onCreate(savedInstanceState);

        drawEdgeToEdge();
        fitSystemBars();
        pageProgress = findViewById(R.id.page_progress);

        WebView webView = bridge.getWebView();
        // Apple Music sign-in: MusicKit JS opens Apple's page with window.open
        // and waits for it to post the member's token back to this page.
        // onCreateWindow (below) gives it a real window to do that in.
        webView.getSettings().setSupportMultipleWindows(true);
        // Don't tell every site the app's package name in X-Requested-With.
        // Google's sign-in pages are among those that treat it as a WebView.
        if (WebViewFeature.isFeatureSupported(WebViewFeature.REQUESTED_WITH_HEADER_ALLOW_LIST)) {
            WebSettingsCompat.setRequestedWithHeaderOriginAllowList(webView.getSettings(), Collections.emptySet());
        }

        injectShellBridge();

        bridge.setWebViewClient(
            new BridgeWebViewClient(bridge) {
                @Override
                public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                    // Capacitor hands any navigation to a host outside
                    // `allowNavigation` to an external app without checking which
                    // frame it is in, and Android WebView may report iframe
                    // navigations here too. iOS only does this for top-level
                    // navigations. Match iOS, so an embedded frame (a video, a
                    // map) is never bounced out to Chrome.
                    if (!request.isForMainFrame()) {
                        return false;
                    }
                    return super.shouldOverrideUrlLoading(view, request);
                }

                @Override
                public void onPageCommitVisible(WebView view, String url) {
                    super.onPageCommitVisible(view, url);
                    // Also fires for the offline page when the site is
                    // unreachable, which is exactly when the splash should go.
                    releaseSplashOnceContentShows(view, 0);
                }

                @Override
                public void onPageFinished(WebView view, String url) {
                    super.onPageFinished(view, url);
                    if (shellBridgeFallback != null && isOnServer(Uri.parse(url))) {
                        view.evaluateJavascript(shellBridgeFallback, null);
                    }
                }
            }
        );

        // A second BridgeWebChromeClient, identical but for progress reporting.
        // Capacitor offers no setter, and the chrome client is the only source
        // of load progress. Safe here: its constructor registers activity-result
        // launchers (the photo picker and camera), which must happen before the
        // activity starts.
        webView.setWebChromeClient(
            new BridgeWebChromeClient(bridge) {
                @Override
                public void onProgressChanged(WebView view, int newProgress) {
                    super.onProgressChanged(view, newProgress);
                    showPageProgress(newProgress);
                }

                @Override
                public boolean onCreateWindow(WebView view, boolean isDialog, boolean isUserGesture, Message resultMsg) {
                    return openPopup(resultMsg);
                }
            }
        );

        setUpBackButton();
    }

    /**
     * Draw behind the status and navigation bars on every Android version, the
     * way Android 15+ already does for targetSdk 35+ and the way iOS works, so
     * fitSystemBars decides the layout the same way everywhere. Without this,
     * Android 14 and below lay the page out between the bars and paint a band
     * under the app's bottom nav.
     */
    private void drawEdgeToEdge() {
        Window window = getWindow();
        WindowCompat.setDecorFitsSystemWindows(window, false);
        window.setStatusBarColor(Color.TRANSPARENT);
        window.setNavigationBarColor(Color.TRANSPARENT);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.setStatusBarContrastEnforced(false);
            window.setNavigationBarContrastEnforced(false);
        }
    }

    /**
     * ratifymusic.com sets viewport-fit=cover and pads its own header and bottom
     * nav with env(safe-area-inset-*), exactly as it does on iOS. WebView 140+
     * reports the system bars to the page that way, so pass the insets
     * through and let the page run edge to edge. Older WebViews report zero,
     * so there the layout root (@id/shell_root) is padded instead and the
     * strips show the app's background. With the keyboard up, the WebView
     * ends above it.
     *
     * This is SystemBars' decor-view listener with that WebView-version rule,
     * which is why SystemBars' insetsHandling is 'disable' in
     * capacitor.config.ts.
     */
    private void fitSystemBars() {
        boolean webViewReportsInsets = webViewMajorVersion() >= 140;
        View decor = getWindow().getDecorView();
        View root = findViewById(R.id.shell_root);
        ViewCompat.setOnApplyWindowInsetsListener(decor, (v, insets) -> {
            int types = WindowInsetsCompat.Type.systemBars() | WindowInsetsCompat.Type.displayCutout();
            Insets bars = insets.getInsets(types);
            boolean keyboard = insets.isVisible(WindowInsetsCompat.Type.ime());
            int imeBottom = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom;
            int padTop = webViewReportsInsets ? 0 : bars.top;
            int padBottom = keyboard ? imeBottom : (webViewReportsInsets ? 0 : bars.bottom);
            root.setPadding(bars.left, padTop, bars.right, padBottom);
            // Returning CONSUMED would stop Chromium recalculating the page's
            // safe area (crbug 461332423), so hand on explicit values.
            int pageTop = webViewReportsInsets ? bars.top : 0;
            int pageBottom = keyboard || !webViewReportsInsets ? 0 : bars.bottom;
            return new WindowInsetsCompat.Builder(insets).setInsets(types, Insets.of(0, pageTop, 0, pageBottom)).build();
        });
        ViewCompat.requestApplyInsets(decor);
    }

    private int webViewMajorVersion() {
        PackageInfo info = WebViewCompat.getCurrentWebViewPackage(this);
        if (info == null || info.versionName == null) return 0;
        try {
            return Integer.parseInt(info.versionName.split("\\.")[0]);
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    /**
     * Back walks the app's own history; on the first page it leaves the app
     * the way Home does. Not @capacitor/app: with no JS listener its handler
     * only calls goBack(), so Back on the first page did nothing at all.
     */
    private void setUpBackButton() {
        getOnBackPressedDispatcher()
            .addCallback(
                this,
                new OnBackPressedCallback(true) {
                    @Override
                    public void handleOnBackPressed() {
                        if (popupDialog != null) {
                            if (popupView != null && popupView.canGoBack()) {
                                popupView.goBack();
                            } else {
                                closePopup();
                            }
                            return;
                        }
                        WebView webView = bridge.getWebView();
                        if (webView.canGoBack()) {
                            webView.goBack();
                        } else {
                            // Keep the activity alive rather than finish(), so
                            // coming back resumes the page instead of reloading it.
                            moveTaskToBack(true);
                        }
                    }
                }
            );
    }

    /**
     * Adds www/shell-bridge.js (copied into assets/public by `cap sync`): the
     * page-transition safety net. At document start where the WebView supports
     * it, restricted to the app's own origin.
     */
    private void injectShellBridge() {
        String script;
        try (InputStream in = getAssets().open("public/shell-bridge.js")) {
            // Not readAllBytes(): that is API 33, and minSdk is 24.
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            for (int n; (n = in.read(buffer)) != -1; ) {
                out.write(buffer, 0, n);
            }
            script = out.toString(StandardCharsets.UTF_8.name());
        } catch (Exception e) {
            Logger.error("shell-bridge.js missing from assets; run `npx cap sync android`", e);
            return;
        }

        // Tells the site (src/lib/nativePush.js) whether this build has its
        // Firebase config (google-services.json): registering for push
        // without it would crash the app.
        boolean firebaseConfigured = getResources().getIdentifier("google_app_id", "string", getPackageName()) != 0;
        script = "window.__ratifyPushAvailable = " + firebaseConfigured + ";\n" + script;

        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            Uri server = Uri.parse(bridge.getServerUrl());
            Set<String> origins = new HashSet<>();
            origins.add(server.getScheme() + "://" + server.getHost());
            WebViewCompat.addDocumentStartJavaScript(bridge.getWebView(), script, origins);
        } else {
            shellBridgeFallback = script;
        }
    }

    /**
     * The HTML arriving is not the app appearing: the Base44 app renders
     * client-side a moment later, and until then the page is blank. Hold the
     * splash until the page shows something (LAUNCH_TIMEOUT_MS still caps it).
     */
    private void releaseSplashOnceContentShows(WebView view, int attempt) {
        if (firstPagePainted) return;
        view.evaluateJavascript(
            "!!document.body && (document.body.innerText.trim().length > 0 || !!document.querySelector('img, svg, video, canvas'))",
            (result) -> {
                if ("true".equals(result) || attempt >= 40) {
                    firstPagePainted = true;
                } else {
                    handler.postDelayed(() -> releaseSplashOnceContentShows(view, attempt + 1), 250);
                }
            }
        );
    }

    private void showPageProgress(int progress) {
        if (progress < 100) {
            if (pageProgress.getVisibility() != View.VISIBLE) {
                pageProgress.animate().cancel();
                pageProgress.setAlpha(1f);
                pageProgress.setProgress(0);
                pageProgress.setVisibility(View.VISIBLE);
            }
            // Never run backwards: a redirect restarts WebView's estimate.
            if (progress > pageProgress.getProgress()) {
                pageProgress.setProgress(progress, true);
            }
            return;
        }

        if (pageProgress.getVisibility() == View.VISIBLE) {
            pageProgress.setProgress(100, true);
            pageProgress
                .animate()
                .alpha(0f)
                .setStartDelay(200)
                .setDuration(300)
                .withEndAction(() -> pageProgress.setVisibility(View.INVISIBLE))
                .start();
        }
    }

    // window.open: Apple Music sign-in

    private Dialog popupDialog;
    private WebView popupView;

    /**
     * A window the page opened with window.open. Only Apple's sign-in pages
     * stay in the app, in a full-screen sheet over the page, with
     * window.opener intact so MusicKit receives the token; any other address
     * (a share link, an outside site) opens in the browser and the window is
     * dropped, as it would be without this.
     */
    private boolean openPopup(Message resultMsg) {
        closePopup();
        WebView popup = new WebView(this);
        WebSettings settings = popup.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setJavaScriptCanOpenWindowsAutomatically(true);
        // Apple's sign-in treats an Android WebView as an unsupported browser;
        // it gets Chrome's own user agent (the WebView's minus "; wv",
        // "Version/4.0" and the app's name).
        settings.setUserAgentString(
            bridge.getWebView().getSettings().getUserAgentString()
                .replace("; wv)", ")")
                .replaceAll("Version/\\d+(\\.\\d+)* ", "")
                .replace(" RatifyApp", "")
        );
        android.webkit.CookieManager.getInstance().setAcceptThirdPartyCookies(popup, true);
        popup.setBackgroundColor(Color.parseColor("#080808"));
        popup.setWebViewClient(
            new WebViewClient() {
                @Override
                public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                    return routePopup(request.getUrl());
                }

                @Override
                public void onPageStarted(WebView view, String url, android.graphics.Bitmap favicon) {
                    super.onPageStarted(view, url, favicon);
                    if (url != null && !url.startsWith("about:")) routePopup(Uri.parse(url));
                }
            }
        );
        popup.setWebChromeClient(
            new WebChromeClient() {
                @Override
                public void onCloseWindow(WebView window) {
                    closePopup();
                }
            }
        );
        popupView = popup;
        WebView.WebViewTransport transport = (WebView.WebViewTransport) resultMsg.obj;
        transport.setWebView(popup);
        resultMsg.sendToTarget();
        return true;
    }

    /** True to cancel the popup's navigation (it went to the browser). */
    private boolean routePopup(Uri url) {
        String host = url.getHost();
        if (host == null) return false;
        if (Base44AuthPlugin.isAppleMusicAuthHost(host) || isOnServer(url)) {
            showPopup();
            return false;
        }
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, url));
        } catch (Exception e) {
            Logger.error("Could not open " + url, e);
        }
        if (popupDialog == null) {
            // Never shown: drop it, as the browser would have taken it.
            handler.post(this::closePopup);
        }
        return true;
    }

    private void showPopup() {
        if (popupDialog != null || popupView == null) return;
        Dialog dialog = new Dialog(this, android.R.style.Theme_Black_NoTitleBar_Fullscreen);
        FrameLayout frame = new FrameLayout(this);
        frame.setBackgroundColor(Color.parseColor("#080808"));
        frame.setFitsSystemWindows(true);
        frame.addView(popupView, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        ImageButton close = new ImageButton(this);
        close.setImageResource(android.R.drawable.ic_menu_close_clear_cancel);
        close.setBackgroundColor(Color.TRANSPARENT);
        close.setContentDescription("Close");
        close.setOnClickListener((v) -> closePopup());
        FrameLayout.LayoutParams closeParams = new FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, android.view.Gravity.TOP | android.view.Gravity.END);
        frame.addView(close, closeParams);
        dialog.setContentView(frame);
        dialog.setOnKeyListener((d, keyCode, event) -> {
            if (keyCode == android.view.KeyEvent.KEYCODE_BACK && event.getAction() == android.view.KeyEvent.ACTION_UP) {
                if (popupView != null && popupView.canGoBack()) popupView.goBack();
                else closePopup();
                return true;
            }
            return keyCode == android.view.KeyEvent.KEYCODE_BACK;
        });
        popupDialog = dialog;
        dialog.show();
    }

    private void closePopup() {
        if (popupDialog != null) {
            popupDialog.setOnKeyListener(null);
            popupDialog.dismiss();
            popupDialog = null;
        }
        if (popupView != null) {
            ViewGroup parent = (ViewGroup) popupView.getParent();
            if (parent != null) parent.removeView(popupView);
            popupView.destroy();
            popupView = null;
        }
    }

    private boolean isOnServer(Uri page) {
        String host = Uri.parse(bridge.getServerUrl()).getHost();
        return host != null && host.equals(page.getHost());
    }

    @Override
    public void onDestroy() {
        closePopup();
        handler.removeCallbacksAndMessages(null);
        super.onDestroy();
    }
}
