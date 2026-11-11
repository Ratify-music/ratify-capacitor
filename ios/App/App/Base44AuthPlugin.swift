import AuthenticationServices
import Capacitor
import WebKit

/// Social sign-in for the Base44 app, plus universal links into it.
///
/// Ratify's "Continue with Apple / Google / Facebook / Microsoft" buttons
/// (SocialSignInButtons.jsx, AppleSignInButton.jsx) call the SDK's
/// `loginWithProvider`, which sends the page to
/// `https://<app host>/api/apps/auth[/<provider>]/login?from_url=<page>&app_id=…`.
/// That 307s to app.base44.com, which runs a full-page OAuth redirect and
/// finally comes back to `<from_url>?access_token=…`. The app's Base44 SDK reads
/// `access_token` from the URL on load and keeps it in localStorage.
///
/// Google refuses OAuth inside embedded WebViews (`disallowed_useragent`), so
/// this plugin catches that first navigation and runs it in an
/// ASWebAuthenticationSession instead (Safari's cookies, so a returning Google
/// user just picks an account). Base44 rejects custom URL schemes as a
/// `from_url` ("Invalid redirect domain"), so the session returns to an https
/// path on the app's own domain, which iOS 17.4+ can catch because the app is
/// associated with its own host (App.entitlements; Base44 already serves the
/// matching apple-app-site-association). The token is then handed to the
/// page it started from, exactly as Base44 would have.
///
/// On iOS 15–17.3 there is no https callback. There the flow is left in the
/// WebView, which is given Safari's user agent for the Google hops only.
@objc(Base44AuthPlugin)
public class Base44AuthPlugin: CAPPlugin, CAPBridgedPlugin, ASWebAuthenticationPresentationContextProviding {
    public let identifier = "Base44AuthPlugin"
    public let jsName = "Base44Auth"
    public let pluginMethods: [CAPPluginMethod] = []

    /// Never a real page: the session is dismissed before it would load.
    static let callbackPath = "/native-auth"

    /// Hosts the sign-in passes through after leaving the app's own domain.
    private static let authHosts: Set<String> = ["app.base44.com", "accounts.google.com"]

    private var session: ASWebAuthenticationSession?
    /// iOS < 17.4 only: true while the WebView itself is on the Google hops.
    private var inWebViewSignIn = false
    private var savedUserAgent: String?
    /// Set once iOS has refused the https callback (see signIn), so later
    /// sign-ins in this launch go straight to the WebView.
    private var httpsCallbackUnavailable = false
    /// The app's previous addresses (`plugins.Base44Auth.legacyHosts` in
    /// capacitor.config.ts). They still serve the same app, but a member's
    /// sign-in is kept per address, so pages there are shown on the app's own
    /// host instead.
    private var legacyHosts: Set<String> = []

    override public func load() {
        legacyHosts = Set((getConfig().getArray("legacyHosts", []) ?? []).compactMap { ($0 as? String)?.lowercased() })
        NotificationCenter.default.addObserver(
            self, selector: #selector(openUniversalLink(_:)), name: .capacitorOpenUniversalLink, object: nil)
        // A link that cold-started the app arrived before this plugin existed.
        if let url = ApplicationDelegateProxy.shared.lastURL, url.scheme == "https" {
            DispatchQueue.main.async { self.open(url) }
        }
    }

    override public func shouldOverrideLoad(_ navigationAction: WKNavigationAction) -> NSNumber? {
        guard navigationAction.targetFrame?.isMainFrame ?? true,
              let url = navigationAction.request.url,
              let serverURL = bridge?.config.serverURL else {
            return nil
        }

        // A link to an old address of the app: show that page on the app's
        // own host, where the member is signed in.
        if let moved = onAppHost(url, serverURL: serverURL) {
            CAPLog.print("⚡️  Base44Auth: \(url.host ?? "") link shown on \(moved.absoluteString)")
            DispatchQueue.main.async { self.bridge?.webView?.load(URLRequest(url: moved)) }
            return true
        }

        if url.host == serverURL.host {
            if inWebViewSignIn && !Self.isProviderLogin(url) { endInWebViewSignIn() }
            guard Self.isProviderLogin(url) else { return nil }
            if inWebViewSignIn { return nil }
            if #available(iOS 17.4, *), !httpsCallbackUnavailable {
                DispatchQueue.main.async { self.signIn(startingAt: url, serverURL: serverURL) }
                return true
            }
            beginInWebViewSignIn()
            return nil
        }

        if inWebViewSignIn, let host = url.host, Self.isAuthHost(host) {
            // Keep the Google hops in the WebView instead of Safari.
            return false
        }
        return nil
    }

    /// `/api/apps/auth/login` (Google), `/api/apps/auth/<provider>/login`, and
    /// Base44 SSO `/api/apps/<app id>/auth/sso/login`.
    private static func isProviderLogin(_ url: URL) -> Bool {
        let parts = url.path.split(separator: "/")
        guard parts.count >= 4, parts[0] == "api", parts[1] == "apps", parts.last == "login" else { return false }
        return parts[2] == "auth" || (parts.count == 6 && parts[3] == "auth" && parts[4] == "sso")
    }

    private static func isAuthHost(_ host: String) -> Bool {
        authHosts.contains(host) || host.hasSuffix(".google.com") || host.hasPrefix("accounts.google.")
    }

    // MARK: - iOS 17.4+: ASWebAuthenticationSession

    @available(iOS 17.4, *)
    private func signIn(startingAt loginURL: URL, serverURL: URL) {
        guard session == nil, let host = serverURL.host,
              var components = URLComponents(url: loginURL, resolvingAgainstBaseURL: false) else { return }

        // Where the page asked to come back to. The token is only ever handed
        // to the app's own origin, never to a host a page could put in from_url.
        var items = components.queryItems ?? []
        let requested = items.first { $0.name == "from_url" }?.value.flatMap(URL.init(string:))
        let returnURL = requested?.host == host ? requested! : serverURL

        var callback = URLComponents()
        callback.scheme = "https"
        callback.host = host
        callback.path = Self.callbackPath
        items.removeAll { $0.name == "from_url" }
        items.append(URLQueryItem(name: "from_url", value: callback.url!.absoluteString))
        components.percentEncodedQuery = items
            .map { "\($0.name)=\(Self.formEncoded($0.value ?? ""))" }
            .joined(separator: "&")
        guard let startURL = components.url else { return }

        let session = ASWebAuthenticationSession(
            url: startURL,
            callback: .https(host: host, path: Self.callbackPath)
        ) { [weak self] callbackURL, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.session = nil
                if let callbackURL {
                    self.complete(with: callbackURL, returnURL: returnURL)
                    return
                }
                let message = (error as NSError?).map { "\($0.localizedDescription) \($0.userInfo)" } ?? ""
                CAPLog.print("⚡️  Base44Auth: sign-in ended: \(message)")
                // iOS refuses https callbacks unless it has verified the app's
                // association with the domain: a build not signed by the team
                // in apple-app-site-association (97Z6JVW7XJ), or before iOS
                // has fetched the file. The error is reported as a cancel, so
                // tell it apart by its text, and sign in in the WebView instead
                // of leaving the button dead.
                if message.contains("not associated") {
                    self.httpsCallbackUnavailable = true
                    self.beginInWebViewSignIn()
                    self.bridge?.webView?.load(URLRequest(url: loginURL))
                }
                // Otherwise the user closed the sheet: leave the page as is.
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if session.start() {
            CAPLog.print("⚡️  Base44Auth: signing in through \(loginURL.path)")
        } else {
            CAPLog.print("⚡️  Base44Auth: could not start the sign-in session")
            self.session = nil
        }
    }

    /// Loads `returnURL` with the callback's `access_token` (and `is_new_user`),
    /// which the page's Base44 SDK picks up on load as it does on the web.
    private func complete(with callbackURL: URL, returnURL: URL) {
        let received = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let token = received.first(where: { $0.name == "access_token" })?.value, !token.isEmpty,
              var target = URLComponents(url: returnURL, resolvingAgainstBaseURL: false) else {
            CAPLog.print("⚡️  Base44Auth: callback without a token")
            return
        }
        var items = (target.queryItems ?? []).filter { $0.name != "access_token" && $0.name != "is_new_user" }
        items.append(URLQueryItem(name: "access_token", value: token))
        if let isNew = received.first(where: { $0.name == "is_new_user" })?.value {
            items.append(URLQueryItem(name: "is_new_user", value: isNew))
        }
        target.percentEncodedQuery = items
            .map { "\($0.name)=\(Self.formEncoded($0.value ?? ""))" }
            .joined(separator: "&")
        guard let url = target.url else { return }
        // A real load, not a client-side route: the SDK and the app's auth
        // context read the token once, at startup.
        bridge?.webView?.load(URLRequest(url: url))
    }

    // MARK: - iOS < 17.4: in the WebView

    private func beginInWebViewSignIn() {
        guard let webView = bridge?.webView else { return }
        inWebViewSignIn = true
        savedUserAgent = webView.customUserAgent
        let version = UIDevice.current.systemVersion.split(separator: ".").prefix(2).joined(separator: ".")
        webView.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS \(version.replacingOccurrences(of: ".", with: "_")) like Mac OS X) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Mobile/15E148 Safari/604.1"
    }

    private func endInWebViewSignIn() {
        inWebViewSignIn = false
        bridge?.webView?.customUserAgent = savedUserAgent
        savedUserAgent = nil
    }

    // MARK: - Universal links

    @objc private func openUniversalLink(_ notification: Notification) {
        guard let object = notification.object as? [String: Any], let url = object["url"] as? URL else { return }
        DispatchQueue.main.async { self.open(url) }
    }

    /// Links to the app's host (the AASA covers every path) open the app; show
    /// that page in it. This is also how a Stripe success page can come back:
    /// if iOS hands Safari's redirect to the app, the page opens here.
    private func open(_ url: URL) {
        guard let serverURL = bridge?.config.serverURL else { return }
        let url = onAppHost(url, serverURL: serverURL) ?? url
        guard url.host == serverURL.host,
              url.path != Self.callbackPath, let webView = bridge?.webView,
              webView.url?.absoluteString != url.absoluteString else { return }
        webView.load(URLRequest(url: url))
    }

    // MARK: -

    /// `url` moved to the app's own host when it points at one of its old
    /// addresses (same path and query), otherwise nil.
    private func onAppHost(_ url: URL, serverURL: URL) -> URL? {
        guard let host = url.host?.lowercased(), legacyHosts.contains(host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = serverURL.scheme
        components.host = serverURL.host
        components.port = serverURL.port
        return components.url
    }

    private static func formEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        bridge?.webView?.window ?? ASPresentationAnchor()
    }
}
