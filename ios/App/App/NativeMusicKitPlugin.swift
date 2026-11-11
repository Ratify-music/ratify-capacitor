import Capacitor
import MediaPlayer
import MusicKit
import StoreKit
import WebKit

/// Apple Music for the Ratify site, through Apple's MusicKit framework.
///
/// The site already has the JavaScript side (src/lib/nativeMusicKit.js in the
/// Base44 repo). When `window.Capacitor.Plugins.NativeMusicKit` exists, its
/// MusicKitContext skips MusicKit JS, whose authorisation popup never returns
/// inside a WebView, and calls these methods instead:
///
///     authorize({ developerToken })  -> { authorized, error? }
///     unauthorize()                  -> {}
///     isAuthorized()                 -> { authorized }
///     play({ queue })                -> { ok, error? }   queue = { songs: [id] } | { album: id }
///     pause() / resume() / stop()    -> {}
///     addListener('playbackEvent')   -> { state: 'playing' | 'paused' | 'ended' | 'stopped' }
///                                       and { progress: 0...1 } while playing
///
/// Authorisation is the system "Allow Ratify Music to access Apple Music?" prompt,
/// answered for the Apple ID signed in on the device, so it never leaves the
/// app. Full-song playback also needs that Apple ID to have an Apple Music
/// subscription; without one, play() resolves `{ ok: false }` with a reason.
///
/// Playback goes through the system's application music player
/// (MPMusicPlayerController.applicationQueuePlayer) by Apple Music catalog id.
/// It needs no developer token, so it does not depend on MusicKit being ticked
/// under App Services for the App ID: MusicKit's catalog requests failed with
/// developerTokenRequestFailed in the TestFlight build. Albums are expanded to
/// their tracks through Apple's public iTunes lookup. The site's own web token
/// (`developerToken`) is not needed.
@objc(NativeMusicKitPlugin)
public class NativeMusicKitPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "NativeMusicKitPlugin"
    public let jsName = "NativeMusicKit"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "authorize", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "unauthorize", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isAuthorized", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pause", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resume", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
    ]

    private static let event = "playbackEvent"

    /// iOS has no way for an app to hand its Apple Music permission back, so
    /// the site's "Disconnect" is remembered here: isAuthorized() reports false
    /// until the member connects again (which then needs no second prompt).
    private static let disconnectedKey = "NativeMusicKit.disconnected"

    private var player: MPMusicPlayerApplicationController { MPMusicPlayerController.applicationQueuePlayer }
    private var playerObservers: [NSObjectProtocol] = []
    private var progressTimer: Timer?
    private var navigationObserver: NSObjectProtocol?

    /// The last state sent to the page, so each change is reported once.
    private var reportedState: String?
    /// The last progress sent, used to tell the end of a song from a pause.
    private var lastProgress: Double = 0
    /// True while the page's own pause()/stop() takes effect, so the status
    /// change it causes is reported as 'paused' and never as 'ended'.
    private var pauseRequested = false
    /// True while play() swaps the queue: the player briefly reports
    /// stopped/paused for the old queue, which the page must not hear after it
    /// has already been told the new song started.
    private var startingPlayback = false

    private var isDisconnected: Bool {
        get { UserDefaults.standard.bool(forKey: Self.disconnectedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.disconnectedKey) }
    }

    override public func load() {
        // In a browser, leaving or reloading the page ends MusicKit JS playback
        // with it. Here the player would outlive the page, and the new page
        // (after sign-in, a reload, coming back from Stripe) has no idea a song
        // is playing and no button to stop it. So a new document stops it.
        navigationObserver = NotificationCenter.default.addObserver(
            forName: .capacitorDecidePolicyForNavigationAction, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let action = notification.object as? WKNavigationAction,
                  action.targetFrame?.isMainFrame == true,
                  self.isNewDocument(action) else { return }
            self.endPlaybackForNewPage()
        }
    }

    deinit {
        if let navigationObserver { NotificationCenter.default.removeObserver(navigationObserver) }
        playerObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Authorisation

    @objc func authorize(_ call: CAPPluginCall) {
        Task { @MainActor in
            var status = MusicAuthorization.currentStatus
            if status == .notDetermined {
                status = await MusicAuthorization.request()
            }
            switch status {
            case .authorized:
                self.isDisconnected = false
                call.resolve(["authorized": true])
            case .denied:
                call.resolve([
                    "authorized": false,
                    "error": "Apple Music access is turned off for Ratify Music. Turn it on in the Settings app under Ratify Music, then try again.",
                ])
            case .restricted:
                call.resolve([
                    "authorized": false,
                    "error": "Apple Music is restricted on this device (Screen Time or device management).",
                ])
            case .notDetermined:
                call.resolve(["authorized": false, "error": "Apple Music authorization was not completed. Please try again."])
            @unknown default:
                call.resolve(["authorized": false, "error": "Apple Music authorization was not completed. Please try again."])
            }
        }
    }

    @objc func unauthorize(_ call: CAPPluginCall) {
        Task { @MainActor in
            self.isDisconnected = true
            if self.player.playbackState != .stopped {
                self.player.stop()
            }
            self.stopProgressTimer()
            self.report("stopped")
            call.resolve([:])
        }
    }

    @objc func isAuthorized(_ call: CAPPluginCall) {
        call.resolve(["authorized": MusicAuthorization.currentStatus == .authorized && !isDisconnected])
    }

    // MARK: - Playback

    @objc func play(_ call: CAPPluginCall) {
        let queue = call.getObject("queue") ?? [:]
        let songIDs = Self.catalogIDs(queue["songs"])
        let albumID = Self.catalogID(queue["album"])
        guard !songIDs.isEmpty || albumID != nil else {
            call.resolve(["ok": false, "error": "queue needs { songs: [id] } or { album: id }"])
            return
        }

        Task { @MainActor in
            guard MusicAuthorization.currentStatus == .authorized, !self.isDisconnected else {
                call.resolve(["ok": false, "error": "Apple Music is not connected"])
                return
            }
            self.startingPlayback = true
            defer { self.startingPlayback = false }
            do {
                // StoreKit's capability check, not MusicSubscription.current:
                // MusicKit's own requests need the developer token this app
                // cannot rely on (see the type comment).
                guard try await Self.canPlayCatalog() else {
                    call.resolve(["ok": false, "error": "An Apple Music subscription is needed to play full songs."])
                    return
                }

                var storeIDs = songIDs
                if let albumID {
                    storeIDs = await Self.albumTrackIDs(albumID)
                    if storeIDs.isEmpty { storeIDs = [albumID] }
                }

                self.pauseRequested = false
                self.lastProgress = 0
                self.observePlayer()
                self.player.setQueue(with: storeIDs)
                try await self.player.prepareToPlay()
                self.player.play()
                guard await self.waitUntilPlaying() else {
                    self.player.stop()
                    call.resolve(["ok": false, "error": "Apple Music couldn't start this song. Please try again."])
                    return
                }
                self.startingPlayback = false
                self.report("playing", force: true)
                self.startProgressTimer()
                call.resolve(["ok": true])
            } catch {
                CAPLog.print("⚡️  NativeMusicKit: play failed: \(error)")
                call.resolve(["ok": false, "error": Self.describe(error)])
            }
        }
    }

    @objc func pause(_ call: CAPPluginCall) {
        Task { @MainActor in
            self.pausePlayback()
            call.resolve([:])
        }
    }

    /// Pauses and keeps the position, exactly like the site's web player:
    /// MusicKitContext.stop() calls MusicKit JS `pause()`, and the song button
    /// (SongPreviewButton) toggles stop()/resume() on the same track. A real
    /// stop would throw the position away, and its 'stopped' event makes the
    /// page forget which song was active, so the next tap would start the song
    /// over instead of resuming it.
    @objc func stop(_ call: CAPPluginCall) {
        Task { @MainActor in
            self.pausePlayback()
            call.resolve([:])
        }
    }

    @objc func resume(_ call: CAPPluginCall) {
        Task { @MainActor in
            guard self.player.nowPlayingItem != nil else {
                call.resolve([:])
                return
            }
            self.pauseRequested = false
            self.player.play()
            self.report("playing")
            self.startProgressTimer()
            call.resolve([:])
        }
    }

    @MainActor
    private func pausePlayback() {
        guard Self.isPlaying(player.playbackState) else { return }
        pauseRequested = true
        player.pause()
        stopProgressTimer()
        report("paused")
    }

    /// play() returns before audio starts; wait for the player to say so
    /// (up to 8 s), so the page is only told "playing" when it is.
    @MainActor
    private func waitUntilPlaying() async -> Bool {
        for _ in 0..<32 {
            if Self.isPlaying(player.playbackState) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return Self.isPlaying(player.playbackState)
    }

    private static func isPlaying(_ state: MPMusicPlaybackState) -> Bool {
        state == .playing || state == .seekingForward || state == .seekingBackward
    }

    // MARK: - Playback events

    @MainActor
    private func observePlayer() {
        guard playerObservers.isEmpty else { return }
        player.beginGeneratingPlaybackNotifications()
        let center = NotificationCenter.default
        for name in [Notification.Name.MPMusicPlayerControllerPlaybackStateDidChange,
                     .MPMusicPlayerControllerNowPlayingItemDidChange] {
            playerObservers.append(center.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.playerStateChanged() }
            })
        }
    }

    @MainActor
    private func playerStateChanged() {
        guard !startingPlayback else { return }
        switch player.playbackState {
        case .playing, .seekingForward, .seekingBackward:
            pauseRequested = false
            report("playing")
            startProgressTimer()
        case .paused, .interrupted:
            stopProgressTimer()
            // Not the page's own pause: a call, Siri, Control Center, another
            // app taking audio, or the queue running out.
            report(!pauseRequested && reachedEnd() ? "ended" : "paused")
        case .stopped:
            stopProgressTimer()
            report(reachedEnd() ? "ended" : "stopped")
        @unknown default:
            break
        }
    }

    /// When the queue finishes, the player stops (or pauses) and drops the
    /// current item, or rewinds it, so the end shows up as no item at all or
    /// the last progress sample being close to 1.
    @MainActor
    private func reachedEnd() -> Bool {
        player.nowPlayingItem == nil || lastProgress >= 0.97
    }

    @MainActor
    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    @MainActor
    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    /// Progress, plus a backstop for state changes: the player's
    /// notifications are not always delivered (for example after an
    /// interruption), so a status that no longer says "playing" is reported here.
    @MainActor
    private func tick() {
        guard Self.isPlaying(player.playbackState) else {
            playerStateChanged()
            return
        }
        guard let duration = player.nowPlayingItem?.playbackDuration, duration > 0 else { return }
        let progress = min(1, max(0, player.currentPlaybackTime / duration))
        lastProgress = progress
        notifyListeners(Self.event, data: ["progress": progress])
    }

    @MainActor
    private func report(_ state: String, force: Bool = false) {
        guard force || state != reportedState else { return }
        reportedState = state
        if state != "playing" && state != "paused" { lastProgress = 0 }
        notifyListeners(Self.event, data: ["state": state])
    }

    // MARK: - Page changes

    /// A main-frame navigation that replaces the document. A link to an anchor
    /// on the same page (only the fragment differs) does not.
    private func isNewDocument(_ action: WKNavigationAction) -> Bool {
        guard let target = action.request.url else { return false }
        guard action.navigationType != .reload, let current = bridge?.webView?.url else { return true }
        var a = URLComponents(url: target, resolvingAgainstBaseURL: false)
        var b = URLComponents(url: current, resolvingAgainstBaseURL: false)
        a?.fragment = nil
        b?.fragment = nil
        return a?.url != b?.url || target.fragment == nil
    }

    @MainActor
    private func endPlaybackForNewPage() {
        guard player.playbackState != .stopped || player.nowPlayingItem != nil else { return }
        player.stop()
        stopProgressTimer()
        report("stopped")
    }

    // MARK: - Helpers

    /// Catalog ids as strings, whether the page sends "1440841363" or a number.
    private static func catalogIDs(_ value: Any?) -> [String] {
        guard let values = value as? [Any] else { return catalogID(value).map { [$0] } ?? [] }
        return values.compactMap(catalogID)
    }

    private static func catalogID(_ value: Any?) -> String? {
        let string: String?
        switch value {
        case let value as String: string = value
        case let value as NSNumber: string = value.stringValue
        default: string = nil
        }
        guard let id = string?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        return id
    }

    /// An album's track ids, in disc and track order, from Apple's public
    /// iTunes lookup in the member's own storefront. Empty if it can't be read.
    private static func albumTrackIDs(_ albumID: String) async -> [String] {
        let country = await storefrontCountry()
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: albumID),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "200"),
        ] + (country.map { [URLQueryItem(name: "country", value: $0)] } ?? [])
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results
            .filter { ($0["wrapperType"] as? String) == "track" }
            .sorted {
                let a = (($0["discNumber"] as? Int) ?? 0, ($0["trackNumber"] as? Int) ?? 0)
                let b = (($1["discNumber"] as? Int) ?? 0, ($1["trackNumber"] as? Int) ?? 0)
                return a < b
            }
            .compactMap { ($0["trackId"] as? NSNumber)?.stringValue }
    }

    /// Whether the Apple ID on the device can play Apple Music catalog songs
    /// (an active subscription). Throws StoreKit's reason when it can't tell.
    private static func canPlayCatalog() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            SKCloudServiceController().requestCapabilities { capabilities, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: capabilities.contains(.musicCatalogPlayback))
                }
            }
        }
    }

    /// The two-letter country of the member's Apple Music storefront.
    private static func storefrontCountry() async -> String? {
        await withCheckedContinuation { continuation in
            SKCloudServiceController().requestStorefrontCountryCode { code, _ in
                continuation.resume(returning: code?.lowercased())
            }
        }
    }

    private static let privacyNoticeMessage =
        "Open the Music app once and accept Apple Music's privacy notice, then try again."
    private static let permissionOffMessage =
        "Apple Music access is turned off for Ratify Music. Turn it on in the Settings app under Ratify Music."

    /// Reasons a member can act on, in place of MusicKit's generic errors.
    private static func describe(_ error: Error) -> String {
        // From MusicSubscription.current, the first thing play() asks.
        if let subscriptionError = error as? MusicSubscription.Error {
            switch subscriptionError {
            case .privacyAcknowledgementRequired: return privacyNoticeMessage
            case .permissionDenied: return permissionOffMessage
            case .unknown: break
            @unknown default: break
            }
        }
        // From StoreKit's capability check.
        if let storeError = error as? SKError {
            switch storeError.code {
            case .privacyAcknowledgementRequired: return privacyNoticeMessage
            case .cloudServicePermissionDenied: return permissionOffMessage
            case .cloudServiceNetworkConnectionFailed:
                return "Couldn't reach Apple Music. Check your connection and try again."
            case .cloudServiceRevoked:
                return "Apple Music access was turned off for this Apple ID. Connect Apple Music again."
            default: break
            }
        }
        // From the player, while it loads the songs.
        if let playerError = error as? MPError {
            switch playerError.code {
            case .notFound:
                return "That song isn't available in Apple Music here."
            case .cloudServiceCapabilityMissing:
                return "An Apple Music subscription is needed to play full songs."
            case .permissionDenied:
                return permissionOffMessage
            case .networkConnectionFailed, .requestTimedOut:
                return "Couldn't reach Apple Music. Check your connection and try again."
            default:
                break
            }
        }
        if let tokenError = error as? MusicTokenRequestError {
            switch tokenError {
            case .developerTokenRequestFailed:
                return "Apple Music couldn't verify the Ratify Music app. Please try again later."
            case .privacyAcknowledgementRequired:
                return privacyNoticeMessage
            case .userNotSignedIn:
                return "Sign in to Apple Music on this device (Settings › Apps › Music), then try again."
            case .permissionDenied:
                return permissionOffMessage
            case .userTokenRevoked, .userTokenRequestFailed, .unknown:
                break
            @unknown default:
                break
            }
        }
        return error.localizedDescription
    }
}
