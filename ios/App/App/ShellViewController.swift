import UIKit
import WebKit
import Capacitor

/// Root view controller: the Capacitor WebView with a page-load progress bar
/// and a launch cover.
///
/// Capacitor's own view controller *is* the WKWebView (`view = webView`), so it
/// is embedded here as a child.
///
/// The site sets `viewport-fit=cover` and pads itself with
/// env(safe-area-inset-*) (globals.css .safe-pt / .safe-pb), so its pages run
/// edge to edge under the status bar and the home indicator. Pages on other
/// hosts that stay in the WebView (Google's sign-in on iOS < 17.4) don't pad
/// themselves, so those sit inside the safe area instead.
final class ShellViewController: UIViewController {

    /// The site's theme colour, #080808 (SURFACE in capacitor.config.ts).
    private static let surface = UIColor(red: 8 / 255, green: 8 / 255, blue: 8 / 255, alpha: 1)
    /// The red of the Ratify badge.
    private static let accent = UIColor(red: 204 / 255, green: 22 / 255, blue: 30 / 255, alpha: 1)
    private static let muted = UIColor(white: 1, alpha: 0.5)

    /// Longest the launch cover waits for the first page before handing over to
    /// the progress bar, so a slow network never looks like a frozen splash.
    private static let launchCoverTimeout: TimeInterval = 10

    private let bridgeViewController = ShellBridgeViewController()
    private let progressBar = UIProgressView(progressViewStyle: .bar)
    private var observations: [NSKeyValueObservation] = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var edgeToEdge: [NSLayoutConstraint] = []
    private var insideSafeArea: [NSLayoutConstraint] = []

    /// Stands in for the SplashScreen plugin: the same image as the launch
    /// storyboard, so the hand-off from the system launch screen is invisible,
    /// held until the first page has actually rendered.
    private let launchCover = UIImageView(image: UIImage(named: "Splash"))
    private let launchSpinner = UIActivityIndicatorView(style: .medium)
    private var firstLoadStarted = false

    /// The page that sent the member to Stripe (Checkout or the billing
    /// portal), which Capacitor opened in Safari. See leftForStripe.
    private var pageLeftForStripe: URL?

    override var childForStatusBarStyle: UIViewController? { bridgeViewController }
    override var childForStatusBarHidden: UIViewController? { bridgeViewController }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        // The app is laid out for a phone held upright; iPad keeps every
        // orientation (required for iPad multitasking).
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Self.surface
        // The site is dark only, so keep system UI (alerts, the sign-in sheet,
        // the Apple Music prompt) dark even when the phone is in light mode.
        overrideUserInterfaceStyle = .dark

        addChild(bridgeViewController)
        let webView = bridgeViewController.view!
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        bridgeViewController.didMove(toParent: self)

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.progressTintColor = Self.accent
        progressBar.trackTintColor = .clear
        progressBar.alpha = 0
        view.addSubview(progressBar)

        edgeToEdge = [
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        insideSafeArea = [
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ]
        NSLayoutConstraint.activate(edgeToEdge)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // Just below the status bar, where the page's own header starts.
            progressBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        configureWebView()
        configureLaunchCover()
        observeWebView()
        observeStripeRoundTrip()
    }

    // MARK: - Setup

    private func configureWebView() {
        guard let webView = bridgeViewController.webView else { return }
        // Edge-swipe back through the app's pages, like Safari.
        webView.allowsBackForwardNavigationGestures = true
        // A long press on a link would otherwise pop up a Safari-style preview
        // of the site's address, which gives the app away as a web page.
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = Self.surface
        webView.scrollView.backgroundColor = Self.surface
    }

    private func configureLaunchCover() {
        launchCover.frame = view.bounds
        launchCover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        launchCover.contentMode = .scaleAspectFill
        launchCover.backgroundColor = Self.surface
        view.addSubview(launchCover)

        // Below the badge. The splash is a 2732px square aspect-filled to the
        // screen height, and the badge is 1100px of it, so its lower edge sits
        // at 50% + 20% of the height.
        launchSpinner.translatesAutoresizingMaskIntoConstraints = false
        launchSpinner.color = Self.muted
        launchSpinner.alpha = 0
        launchSpinner.startAnimating()
        launchCover.addSubview(launchSpinner)
        NSLayoutConstraint.activate([
            launchSpinner.centerXAnchor.constraint(equalTo: launchCover.centerXAnchor),
            NSLayoutConstraint(item: launchSpinner, attribute: .centerY, relatedBy: .equal,
                               toItem: launchCover, attribute: .bottom, multiplier: 0.70, constant: 36),
        ])

        // Only show the spinner when the load is actually slow; a fast launch
        // should be a clean splash straight into the page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.launchSpinner.alpha = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchCoverTimeout) { [weak self] in
            self?.removeLaunchCover()
        }
    }

    private func observeWebView() {
        guard let webView = bridgeViewController.webView else { return }

        observations.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async { self?.updateProgress(for: webView) }
        })

        observations.append(webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateProgress(for: webView)
                if webView.isLoading {
                    self.firstLoadStarted = true
                } else if self.firstLoadStarted {
                    // Also fires when the load fails and Capacitor shows the
                    // offline page, which is exactly when the cover should go.
                    self.removeLaunchCoverOnceContentShows(in: webView)
                    #if DEBUG
                    self.bridgeViewController.runDebugHooksIfRequested()
                    #endif
                }
            }
        })

        observations.append(webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async { self?.fitLayout(for: webView) }
        })
    }

    // MARK: - Stripe

    /// Stripe Checkout and the billing portal open in Safari, on purpose:
    /// Apple Pay works there. The site sends the whole page to Stripe
    /// (`window.location.href = url`), and Capacitor hands any off-site
    /// navigation to Safari and cancels it here, so the page that started it
    /// stays on screen exactly as it was, typically with its button still
    /// showing "Redirecting…". When the member comes back to the app, reload
    /// that page, so it resets and shows the new credit balance or plan.
    private func observeStripeRoundTrip() {
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: .capacitorDecidePolicyForNavigationAction, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let action = notification.object as? WKNavigationAction,
                  action.targetFrame?.isMainFrame ?? true,
                  let host = action.request.url?.host?.lowercased(),
                  host == "stripe.com" || host.hasSuffix(".stripe.com") else { return }
            self.pageLeftForStripe = self.bridgeViewController.webView?.url
        })
        notificationObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let page = self.pageLeftForStripe else { return }
            self.pageLeftForStripe = nil
            // A beat later: if iOS opened the app for Stripe's success page
            // (a universal link), that page is already loading; leave it be.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let webView = self.bridgeViewController.webView,
                      !webView.isLoading, webView.url == page else { return }
                webView.reload()
            }
        })
    }

    // MARK: - Layout

    /// The app's own pages pad themselves for the status bar and home
    /// indicator; pages on other hosts (and the offline page's error states)
    /// sit inside the safe area on the app's dark surface.
    private func fitLayout(for webView: WKWebView) {
        guard let url = webView.url else { return }
        let appHost = bridgeViewController.bridge?.config.serverURL.host
        // localhost is the bundled offline page (server.errorPath), which pads
        // itself too.
        let ownPage = url.host == appHost || url.host == "localhost" || url.isFileURL
        let wasOwnPage = edgeToEdge.first?.isActive ?? true
        guard ownPage != wasOwnPage else { return }
        if ownPage {
            NSLayoutConstraint.deactivate(insideSafeArea)
            NSLayoutConstraint.activate(edgeToEdge)
        } else {
            NSLayoutConstraint.deactivate(edgeToEdge)
            NSLayoutConstraint.activate(insideSafeArea)
        }
    }

    /// The HTML arriving is not the app appearing: the Base44 app renders
    /// client-side a moment later, and until then the page is blank. Keep the
    /// cover until the page shows something (or the launch timeout).
    private func removeLaunchCoverOnceContentShows(in webView: WKWebView, attempt: Int = 0) {
        guard launchCover.superview != nil else { return }
        let probe = "!!document.body && (document.body.innerText.trim().length > 0 || !!document.querySelector('img, svg, video, canvas'))"
        webView.evaluateJavaScript(probe) { [weak self] result, _ in
            guard let self else { return }
            if (result as? Bool) == true || attempt >= 40 {
                self.removeLaunchCover()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.removeLaunchCoverOnceContentShows(in: webView, attempt: attempt + 1)
                }
            }
        }
    }

    // MARK: - Loading UI

    private func updateProgress(for webView: WKWebView) {
        // The launch cover is its own loading indicator.
        guard launchCover.superview == nil else { return }
        if webView.isLoading {
            if progressBar.alpha == 0 {
                progressBar.setProgress(0, animated: false)
                progressBar.alpha = 1
            }
            let progress = Float(webView.estimatedProgress)
            // Never run backwards: a redirect restarts WebKit's estimate.
            if progress > progressBar.progress {
                progressBar.setProgress(progress, animated: true)
            }
        } else if progressBar.alpha > 0 {
            progressBar.setProgress(1, animated: true)
            UIView.animate(withDuration: 0.3, delay: 0.2, options: [.beginFromCurrentState], animations: {
                self.progressBar.alpha = 0
            })
        }
    }

    private func removeLaunchCover() {
        guard launchCover.superview != nil else { return }
        UIView.animate(withDuration: 0.25, animations: { self.launchCover.alpha = 0 }) { _ in
            self.launchCover.removeFromSuperview()
        }
    }
}

/// Capacitor's view controller, extended with the shell's local plugins and
/// www/shell-bridge.js.
final class ShellBridgeViewController: CAPBridgeViewController {

    /// Capacitor animates this (UIView.animate, 0.2 s). An animation block
    /// running while a Base44 page does its own framer-motion route transition
    /// can freeze WebKit's animations mid-way, leaving the new page at
    /// opacity 0 (seen in another Base44 app). Apply it immediately instead.
    override func setStatusBarStyle(_ statusBarStyle: UIStatusBarStyle) {
        self.statusBarStyle = statusBarStyle
        setNeedsStatusBarAppearanceUpdate()
    }

    override func capacitorDidLoad() {
        // Capacitor lets any script focus() raise the keyboard
        // (prepareWebView → setKeyboardShouldRequireUserInteraction(false)).
        // The site's sign-in page autofocuses the email field, which in mobile
        // Safari does nothing until the member taps, but here opened the
        // keyboard over the sign-in buttons on every launch. nil restores
        // WebKit's own rule: the keyboard follows a tap, and stays up while
        // focus moves between fields (one-time code boxes).
        webView?.capacitor.setKeyboardShouldRequireUserInteraction(nil)

        // Plugins in the app target aren't found by Capacitor's plugin scan,
        // which only covers packages; register them by hand. Each one also
        // gets a `window.Capacitor.Plugins.<jsName>` object in every page,
        // which is how the site finds NativeMusicKit.
        bridge?.registerPluginInstance(NativeMusicKitPlugin())
        bridge?.registerPluginInstance(Base44AuthPlugin())
        bridge?.registerPluginInstance(StoreKitPlugin())

        // Added here, not in webViewConfiguration(for:): Capacitor replaces that
        // configuration's userContentController with its own right afterwards,
        // which silently drops anything added to it there. Added after the
        // plugins above, so it runs after their exported objects exist.
        //
        // `cap sync` copies www/ into the app bundle as public/.
        if let url = Bundle.main.url(forResource: "shell-bridge", withExtension: "js", subdirectory: "public"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            webView?.configuration.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        } else {
            CAPLog.print("⚡️  shell-bridge.js missing from the bundle; run `npx cap sync ios`")
        }

        #if DEBUG
        // Safari → Develop → Simulator / device, for debug builds only.
        if #available(iOS 16.4, *) { webView?.isInspectable = true }
        #endif
    }

    #if DEBUG
    private var selfTestStarted = false
    private var debugScriptRun = false

    /// Debug builds only: hooks for testing the shell from the command line.
    func runDebugHooksIfRequested() {
        runSelfTestIfRequested()
        runDebugScriptIfRequested()
    }

    /// Launched with `-ShellDebugJS "<script>"`, runs that script once in the
    /// first page, e.g. to send it to Stripe or start a social sign-in the way
    /// the site's buttons do, without tapping.
    private func runDebugScriptIfRequested() {
        guard !debugScriptRun, let script = UserDefaults.standard.string(forKey: "ShellDebugJS"),
              let webView, webView.url?.host == bridge?.config.serverURL.host else { return }
        debugScriptRun = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            CAPLog.print("⚡️  [debug-js] running: \(script)")
            webView.evaluateJavaScript(script) { _, error in
                if let error { CAPLog.print("⚡️  [debug-js] failed: \(error)") }
            }
        }
    }

    /// Debug builds only. Launched with `-NativeMusicKitSelfTest YES`, this
    /// drives the plugin from inside the page the way the site's
    /// MusicKitContext does, and logs every result (simctl launch
    /// --console-pty). It proves the JS object exists and that each call
    /// reaches native code, without a Ratify account.
    private func runSelfTestIfRequested() {
        guard !selfTestStarted, UserDefaults.standard.bool(forKey: "NativeMusicKitSelfTest"),
              let webView, webView.url?.host == bridge?.config.serverURL.host else { return }
        selfTestStarted = true
        let script = """
        const p = window.Capacitor && window.Capacitor.Plugins && window.Capacitor.Plugins.NativeMusicKit;
        const out = { bridge: !!p, shell: !!window.__ratifyShell };
        if (!p) return JSON.stringify(out);
        const listener = p.addListener('playbackEvent', (e) => console.log('[self-test] playbackEvent ' + JSON.stringify(e)));
        out.addListenerReturnsPromise = !!listener && typeof listener.then === 'function';
        out.isAuthorizedBefore = await p.isAuthorized();
        out.authorize = await p.authorize({ developerToken: 'not-needed' });
        out.isAuthorizedAfter = await p.isAuthorized();
        out.play = await p.play({ queue: { songs: ['1440841363'] } });
        out.badQueue = await p.play({ queue: {} });
        out.stop = await p.stop();
        return JSON.stringify(out);
        """
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): CAPLog.print("⚡️  [self-test] \(value ?? "nil")")
                case .failure(let error): CAPLog.print("⚡️  [self-test] failed: \(error)")
                }
            }
        }
    }
    #endif
}
